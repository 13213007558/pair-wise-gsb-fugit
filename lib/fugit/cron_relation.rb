# frozen_string_literal: true

require 'date'

module Fugit

  class Cron

    # Compares the occurrence sets of two cron schedules and returns
    # a Fugit::Cron::Relation instance.
    #
    #   Fugit::Cron.relate('0 0 * * 1', '0 0 * * 1,2', '2026-10-01 UTC')
    #     # => #<Fugit::Cron::Relation:subset ...>
    #
    # The +from+ argument is the comparison starting point, the relation
    # computes the earliest "witness" time from that point on, that
    # distinguishes the two schedules (nil when they are equivalent).
    #
    def self.relate(a, b, from=nil)

      Relation.new(a, b, from)
    end

    # Instance counterpart to Fugit::Cron.relate()
    #
    #   Fugit::Cron.parse('0 0 * * 1').relation_to('0 0 * * 1,2')
    #
    def relation_to(other, from=nil)

      Fugit::Cron.relate(self, other, from)
    end

    # Analyses the set relation between the occurrence sets of two
    # cron schedules.
    #
    # The analysis is exact.  It does not "try out" a limited time
    # window, nor does it scan the Gregorian cycle second by second.
    # In UTC or in a fixed offset timezone, a cron occurrence set is
    # the cartesian product of a set of calendar dates and a set of
    # times of day.  The date set is periodic over the 400 year
    # Gregorian cycle, and within that cycle a whole month is described
    # by its signature (month, number of days, weekday of the 1st),
    # so the relation is decided by comparing day sets per signature
    # and time-of-day sets componentwise.
    #
    # The relation is one of:
    #
    #   :equal        both schedules trigger at the same instants
    #   :subset       cron a triggers strictly less often than cron b
    #                 (all of a's triggers are b's, but not vice versa)
    #   :superset     the converse of :subset
    #   :overlap      the schedules share triggers, but neither
    #                 contains the other
    #   :disjoint     the schedules never trigger at the same instant
    #   :undecidable  the relation cannot be decided (see #reason)
    #
    # When the relation is not :equal or :undecidable, #witness is the
    # earliest time at or after +from+ where exactly one of the two
    # schedules triggers, and #witness_cron tells which one (:a or :b).
    #
    # The analysis is limited to UTC and fixed offset timezones, both
    # crons must live in the same one.  It returns :undecidable, with
    # one of the following #reasons, for:
    #
    #   :random_syntax       a cron string uses the random '~' syntax
    #   :weekday_modulo      a cron uses the weekday modulo '%' syntax
    #   :dynamic_timezone    a cron (or the +from+ fallback) uses a
    #                        timezone that is not UTC or a fixed offset
    #   :conflicting_zones   the two crons do not share the same offset
    #
    class Relation

      RELATIONS =
        %i[ equal subset superset overlap disjoint undecidable ].freeze
      REASONS =
        %i[ random_syntax weekday_modulo dynamic_timezone conflicting_zones
          ].freeze

      GREGORIAN_CYCLE_YEARS = 400
      CYCLE_FIRST_YEAR = 2000 # any 400 consecutive years would do
      MONTHS_PER_CYCLE = GREGORIAN_CYCLE_YEARS * 12

      # a timezone is considered "fixed" when it knows no transition
      # in this window
      #
      FIXED_PROBE_FROM = Time.utc(1800).freeze
      FIXED_PROBE_TO = Time.utc(2200).freeze

      attr_reader :cron_a, :cron_b, :from
      attr_reader :relation, :reason, :witness, :witness_cron

      def initialize(a, b, from)

        @cron_a = Fugit::Cron.do_parse(a)
        @cron_b = Fugit::Cron.do_parse(b)
        @from = from ? ::EtOrbi.make_time(from) : ::EtOrbi::EoTime.now

        @daysets = {}

        @relation, @reason, @witness, @witness_cron = compute
      end

      RELATIONS.each do |rel|

        define_method("#{rel}?") { @relation == rel }
      end
      alias intersect? overlap?

      def to_h

        { relation: @relation,
          reason: @reason,
          witness: @witness,
          witness_cron: @witness_cron }
      end

      def to_s

        s = "#<#{self.class.name}:#{@relation}"
        s << " #{@reason}" if @reason
        s << " witness: #{@witness.to_s} (#{@witness_cron})" if @witness
        s << '>'
      end
      alias inspect to_s

      protected

      def compute

        za = @cron_a.timezone || @from.zone
        zb = @cron_b.timezone || @from.zone

        oa = fixed_offset(za)
        ob = fixed_offset(zb)

        if reason = undecidable_reason(oa, ob)
          return [ :undecidable, reason, nil, nil ]
        end

        @zone = za # same fixed offset as zb

        ta = tod_lists(@cron_a)
        tb = tod_lists(@cron_b)

        rel = combine_relations(date_relation, tod_relation(ta, tb))

        return [ rel, nil, nil, nil ] if rel == :equal

        w, wc = find_witness(ta, tb)

        [ rel, nil, w, wc ]
      end

      # -- decidability

      def undecidable_reason(oa, ob)

        return :random_syntax \
          if @cron_a.original.include?('~') || @cron_b.original.include?('~')
        return :weekday_modulo \
          if modulo_weekday?(@cron_a) || modulo_weekday?(@cron_b)
        return :dynamic_timezone if oa.nil? || ob.nil?
        return :conflicting_zones if oa != ob

        nil
      end

      def modulo_weekday?(cron)

        ws = cron.weekdays
        ws != nil && ws.any? { |wd| wd[1].is_a?(Array) }
      end

      # Returns the fixed offset in seconds for the given timezone,
      # or nil when the timezone is not a fixed offset one (it observes
      # or observed transitions, like DST, in the probe window).
      #
      def fixed_offset(tz)

        return nil unless tz && tz.respond_to?(:transitions_up_to)
        return nil if tz.transitions_up_to(FIXED_PROBE_TO, FIXED_PROBE_FROM).any?

        tz.period_for_utc(Time.utc(2000, 1, 1)).utc_total_offset
      rescue StandardError
        nil
      end

      # -- date sets

      # A month signature: [ month, day count, weekday of the 1st ].
      # Two months with the same signature see the two crons match the
      # exact same days of the month.
      #
      def month_signature(y, m)

        [ m, ::Date.new(y, m, -1).day, ::Date.new(y, m, 1).wday ]
      end

      def dayset(cron, sig)

        (@daysets[cron.object_id] ||= {})[sig] ||= compute_dayset(cron, sig)
      end

      # The days of the month (1..31) on which the cron's date part
      # (months, monthdays, weekdays) matches, for a month bearing
      # the given signature.
      #
      def compute_dayset(cron, sig)

        m, dim, _wd1 = sig

        months = cron.months
        return [] if months && ! months.include?(m)

        mds = cron.monthdays
        wds = cron.weekdays

        mds = mds && mds
          .collect { |d| d < 1 ? dim + 1 + d : d }
          .select { |d| d >= 1 && d <= dim }
        wds = wds && weekday_days(wds, dim, sig[2])

        if mds && wds
          cron.day_and ? (mds & wds).sort : (mds | wds).sort
        else
          mds || wds || (1..dim).to_a
        end
      end

      def weekday_days(wds, dim, wd1)

        days = []

        wds.each do |wd, hom|

          occs = []
          d = 1 + (wd - wd1) % 7
          while d <= dim
            occs << d
            d += 7
          end

          if hom.nil?
            days.concat(occs)
          else
            n = occs.length
            occs.each_with_index do |dd, i|
              days << dd if hom == i + 1 || hom == i - n
                # i + 1: nth weekday from the beginning of the month
                # i - n: nth weekday from the end of the month (-1 is last)
            end
          end
        end

        days.uniq.sort
      end

      # The relation between the date sets of the two crons, over one
      # full Gregorian cycle (400 years).  Months are grouped by
      # signature, so at most 400 * 12 months are visited, and at most
      # 12 * 2 * 7 distinct day set pairs are computed.
      #
      def date_relation

        a_not_b = false
        b_not_a = false
        inter = false
        seen = {}

        y = CYCLE_FIRST_YEAR

        GREGORIAN_CYCLE_YEARS.times do
          1.upto(12) do |m|

            sig = month_signature(y, m)

            unless seen[sig]
              seen[sig] = true

              sa = dayset(@cron_a, sig)
              sb = dayset(@cron_b, sig)

              a_not_b ||= (sa - sb).any?
              b_not_a ||= (sb - sa).any?
              inter ||= (sa & sb).any?
            end

            return :overlap if a_not_b && b_not_a && inter
          end
          y += 1
        end

        set_relation(a_not_b, b_not_a, inter)
      end

      # -- time of day sets

      # [ seconds, minutes, hours ], each a sorted array of integers,
      # nil ("*") expanded to the full range
      #
      def tod_lists(cron)

        [ cron.seconds || (0..59).to_a,
          cron.minutes || (0..59).to_a,
          cron.hours || (0..23).to_a ]
      end

      def tod_relation(ta, tb)

        a_not_b = false
        b_not_a = false
        inter = true

        3.times do |i|
          ca = ta[i]
          cb = tb[i]
          a_not_b ||= (ca - cb).any?
          b_not_a ||= (cb - ca).any?
          inter &&= (ca & cb).any?
        end

        set_relation(a_not_b, b_not_a, inter)
      end

      # -- relations

      def set_relation(a_not_b, b_not_a, inter)

        if ( ! a_not_b) && ( ! b_not_a) then :equal
        elsif ( ! a_not_b) then :subset
        elsif ( ! b_not_a) then :superset
        elsif ( ! inter) then :disjoint
        else :overlap
        end
      end

      # The occurrence sets are cartesian products (date set x
      # time-of-day set), hence:
      #
      def combine_relations(dr, tr)

        return :equal if dr == :equal && tr == :equal

        if %i[ equal subset ].include?(dr) && %i[ equal subset ].include?(tr)
          :subset
        elsif %i[ equal superset ].include?(dr) &&
              %i[ equal superset ].include?(tr)
          :superset
        elsif dr == :disjoint || tr == :disjoint
          :disjoint
        else
          :overlap
        end
      end

      # -- witness

      # The earliest time at or after @from where exactly one of the
      # two crons triggers.  Months are visited in turn (at most one
      # full Gregorian cycle), days in a month in order, so the first
      # hit is the earliest witness.
      #
      def find_witness(ta, tb)

        t0 = @from.translate(@zone)
        y = t0.year
        m = t0.month
        sd = t0.day
        st = t0.hour * 3600 + t0.min * 60 + t0.sec

        in_a = tod_matcher(ta)
        in_b = tod_matcher(tb)

        MONTHS_PER_CYCLE.times do

          sig = month_signature(y, m)
          sa = dayset(@cron_a, sig)
          sb = dayset(@cron_b, sig)

          (sa | sb).sort.each do |d|

            next if d < sd
            limit = (d == sd) ? st : 0

            fa = sa.include?(d)
            fb = sb.include?(d)

            tod, owner =
              if fa && fb
                xa = first_tod(ta, limit, &in_b)
                xb = first_tod(tb, limit, &in_a)
                xa && (xb.nil? || xa <= xb) ? [ xa, :a ] : [ xb, :b ]
              elsif fa
                [ first_tod(ta, limit), :a ]
              else
                [ first_tod(tb, limit), :b ]
              end

            if tod
              w = (::EtOrbi.make(y, m, d, @zone) + tod).translate(@from.zone)
              return [ w, owner ]
            end
          end

          m += 1
          if m > 12; m = 1; y += 1; end
          sd = 1
          st = 0
        end

        [ nil, nil ] # cannot happen when the relation is not :equal
      end

      # A lambda telling if (hour, minute, second) belongs to the
      # given time-of-day lists
      #
      def tod_matcher(lists)

        ss, mm, hh = lists
          .collect { |l| a = {}; l.each { |i| a[i] = true }; a }

        lambda { |h, mi, se| hh[h] && mm[mi] && ss[se] }
      end

      # The earliest time of day (in seconds since midnight) in the
      # given lists, at or after +limit+.  When a block is given,
      # times for which the block returns true are skipped (used to
      # compute the difference of two time-of-day sets).
      #
      def first_tod(lists, limit)

        ss, mm, hh = lists

        lh = limit / 3600
        lm = limit / 60 % 60
        ls = limit % 60

        hh.each do |h|
          next if h < lh
          mm.each do |mi|
            next if h == lh && mi < lm
            ss.each do |se|
              next if h == lh && mi == lm && se < ls
              next if block_given? && yield(h, mi, se)
              return h * 3600 + mi * 60 + se
            end
          end
        end

        nil
      end
    end
  end
end
