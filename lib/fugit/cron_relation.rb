# frozen_string_literal: true

module Fugit

  # Analysis of the relation between two cron schedules, viewed as sets of
  # fire instants over an infinite horizon.
  #
  # The schedules are compared symbolically, no occurrence is "tried":
  # in a constant-offset zone, the Gregorian calendar repeats exactly every
  # 400 years (146097 days), so each cron is summarized as
  #
  #   * a day mask:  one bit per day of the 400-year cycle
  #   * a time-of-day mask: one bit per second of the day
  #
  # and set relations (equality, directed containment, intersection,
  # disjointness) are decided on those masks with bit operations.
  #
  # Out of scope (reported as :undecidable, with a reason):
  #
  #   * dynamic timezones (anything with DST transitions)
  #   * crons that do not share UTC / the same fixed UTC offset
  #   * the weekday modulo notation ("mon%2", "fri%4+1")
  #   * the random "~" notation
  #
  class CronRelation

    # The Gregorian calendar repeats every 400 years (146097 days).
    # That cycle is exact (leap years included), nothing is simulated.
    #
    CYCLE_YEARS = 400
    CYCLE_DAYS = 146097
    CYCLE_SECONDS = CYCLE_DAYS * 86400
    TOD_SECONDS = 86400

    # The canonical cycle starts at 2000-01-01, a Saturday (wday 6).
    #
    EPOCH_YEAR = 2000
    EPOCH_ABS = 10957 # days from 1970-01-01 to 2000-01-01

    # The outcome of comparing two crons.
    #
    # #relation is one of:
    #
    #   :equal        both schedules fire at exactly the same instants
    #   :contains     a fires at every instant b fires at, and more
    #   :contained    b fires at every instant a fires at, and more
    #   :intersects   they share instants, but each also has its own
    #   :disjoint     they never fire at the same instant
    #   :undecidable  the input is out of scope, see #reason
    #
    # #witness is, for all relations but :equal and :undecidable, the
    # earliest instant at or after the caller-provided "from" at which the
    # two schedules differ. #side says which schedule fires there
    # (`:a` or `:b`).
    #
    Result =
      Struct.new(:relation, :witness, :side, :reason, :from) do

        def equal?; relation == :equal; end
        def contains?; relation == :contains; end
        def contained?; relation == :contained; end
        def intersects?; relation == :intersects; end
        def disjoint?; relation == :disjoint; end
        def undecidable?; relation == :undecidable; end
      end

    def self.analyze(a, b, from=::EtOrbi::EoTime.now)

      new(a, b).analyze(from)
    end

    class << self

      alias compare analyze
      alias relation analyze
    end

    def initialize(a, b)

      @ca = ::Fugit.do_parse_cron(a)
      @cb = ::Fugit.do_parse_cron(b)
    end

    def analyze(from)

      from = floor_second(::EtOrbi.make_time(from))

      reason = guard
      return Result.new(:undecidable, nil, nil, reason, from) if reason

      zone = @ca.timezone

      da, ta = day_mask(@ca), tod_mask(@ca)
      db, tb = day_mask(@cb), tod_mask(@cb)

      rel = determine(da, ta, db, tb)

      return Result.new(:equal, nil, nil, nil, from) if rel == :equal

      wit, side = earliest_witness(rel, from, zone, da, ta, db, tb)

      Result.new(rel, wit, side, nil, from)
    end

    protected

    def determine(da, ta, db, tb)

      a_only_days = da & ~db
      b_only_days = db & ~da
      shared_days = da & db

      common_slots = ta & tb

      if a_only_days == 0 && b_only_days == 0
        # same day set, relations depend only on the time-of-day masks
        #
        if (ta ^ tb) == 0
          :equal
        elsif ta & ~tb == 0
          :contained
        elsif tb & ~ta == 0
          :contains
        elsif common_slots != 0
          :intersects
        else
          :disjoint
        end
      elsif shared_days == 0 || common_slots == 0
        :disjoint
      elsif a_only_days == 0 && ta & ~tb == 0
        :contained
      elsif b_only_days == 0 && tb & ~ta == 0
        :contains
      else
        :intersects
      end
    end

    # nil when in scope, a String explaining why it is not otherwise.
    #
    def guard

      return 'random "~" notation is not decidable' \
        if @ca.original.include?('~') || @cb.original.include?('~')
        #
        # "~" picks a pseudo-random field value at parse time, the schedule
        # cannot be known from the source alone

      [ @ca, @cb ].each do |c|
        if c.weekdays && c.weekdays.any? { |_, h| h.is_a?(::Array) }
          return 'weekday modulo notation ("%n") is not decidable'
          #
          # "mon%2" counts ISO reference weeks (EtOrbi rweek); its period
          # does not fold onto the 400-year Gregorian day cycle
        end
      end

      oa = fixed_offset(@ca)
      ob = fixed_offset(@cb)

      return 'a dynamic (non constant-offset) timezone is not decidable' \
        if oa.nil? || ob.nil?
      return 'the two crons do not share the same fixed UTC offset' \
        if oa != ob

      nil
    end

    # nil unless the cron sits in a constant-offset zone, else the offset
    # in seconds. A cron with no explicit zone is taken to run in UTC.
    #
    def fixed_offset(c)

      tz = c.timezone

      return 0 if tz.nil?

      info = (tz.send(:info) rescue nil)

      return nil unless info.is_a?(
        ::TZInfo::DataSources::ConstantOffsetDataTimezoneInfo)

      tz.period_for_utc(::Time.utc(2024, 1, 1)).utc_total_offset
    end

    # A schedule is the Cartesian product of a repeating day mask and a
    # repeating time-of-day mask.
    #
    def tod_mask(c)

      m = 0

      (c.hours || (0..23).to_a).each do |h|
        (c.minutes || (0..59).to_a).each do |mi|
          (c.seconds || [ 0 ]).each { |s| m |= 1 << (h * 3600 + mi * 60 + s) }
        end
      end

      m
    end

    def day_mask(c)

      mons = c.months
      mdays = c.monthdays
      wdays = c.weekdays
      day_and = c.instance_variable_get(:@day_and)

      m = 0
      bit = 0

      calendar.each do |len, fw, month|

        unless mons.nil? || mons.include?(month)
          bit += len
          next
        end

        dm = mdays ? monthday_local_mask(mdays, len) : nil
        wm = wdays ? weekday_local_mask(wdays, len, fw) : nil

        local =
          if mdays && wdays
            day_and ? (dm & wm) : (dm | wm)
          else
            dm || wm || ((1 << len) - 1)
          end

        m |= local << bit
        bit += len
      end

      m
    end

    # Bits, within a month, of the cron's month-day list.
    # Negative values count back from the last day (fugit: -1 == last).
    #
    def monthday_local_mask(mdays, len)

      m = 0

      mdays.each do |x|
        d = x < 1 ? len + 1 + x : x
        m |= 1 << (d - 1) if d >= 1 && d <= len
      end

      m
    end

    # Bits, within a month, of the cron's weekday list, honouring the
    # "nth of month" (#1..#5) and "last nth" (#-1..#-5) extensions.
    #
    def weekday_local_mask(wdays, len, fw)

      m = 0

      wdays.each do |wd, h|

        off = (wd - fw) % 7 # offset of the first such weekday in the month

        next if off >= len

        if h.nil?
          k = off
          while k < len
            m |= 1 << k
            k += 7
          end
        elsif h.is_a?(::Integer)
          if h > 0
            k = off + (h - 1) * 7
            m |= 1 << k if k < len
          else
            last = off + ((len - 1 - off) / 7) * 7
            k = last + (h + 1) * 7 # #-1 -> last, #-2 -> last-7, ...
            m |= 1 << k if k >= 0
          end
        end
      end

      m
    end

    # Earliest instant at/after "from" that distinguishes the two sets.
    #
    # The symmetric difference is enumerated as a few (day-mask, slot-mask,
    # side) streams: a-only days fire all of a's slots, shared days only
    # fire the slots one side has and the other lacks. Within a stream the
    # next witness is found by searching for the next set bit, never by
    # scanning days or seconds.
    #
    def earliest_witness(rel, from, zone, da, ta, db, tb)

      wall = from.translate(zone)

      from_abs = abs_day_index(wall.year, wall.month, wall.day)

      fdi = mod(from_abs - EPOCH_ABS, CYCLE_DAYS)
      ftod = wall.hour * 3600 + wall.min * 60 + wall.sec

      streams =
        case rel
        when :contains # a is the bigger set
          [ [ da & ~db, ta, :a ], [ da & db, ta & ~tb, :a ] ]
        when :contained # b is the bigger set
          [ [ db & ~da, tb, :b ], [ da & db, tb & ~ta, :b ] ]
        else
          [ [ da & ~db, ta, :a ],
            [ db & ~da, tb, :b ],
            [ da & db, ta & ~tb, :a ],
            [ da & db, tb & ~ta, :b ] ]
        end

      candidates =
        streams
          .collect { |dm, tm, side| stream_witness(dm, tm, fdi, ftod, side) }
          .compact

      fail('internal error: a non equal relation should have a witness') \
        if candidates.empty?

      elapsed, _, _, slot, side =
        candidates.min_by { |el, _, _, sl, _| [ el, sl ] }

      y, mo, d = civil_from_abs(from_abs + elapsed)

      t = ::EtOrbi.make_time(
        '%04d-%02d-%02d %02d:%02d:%02d' %
          [ y, mo, d, slot / 3600, (slot % 3600) / 60, slot % 60 ],
        zone || 'UTC')

      [ t, side ]
    end

    # Returns [ elapsed_days_from_the_from_day, cycle, canonical_day_index,
    # slot, side ] for the earliest fire of the stream at/after "from",
    # or nil if the stream never fires (empty masks).
    #
    def stream_witness(daymask, slotmask, fdi, ftod, side)

      return nil if daymask == 0 || slotmask == 0

      first_slot = lowest_set_bit(slotmask)

      # 1) the from day itself, when it is a day of this stream and one of
      #    the slots is at or after "from"'s time-of-day
      #
      if ((daymask >> fdi) & 1) == 1
        sl = next_set_bit(slotmask, ftod)
        return [ 0, 0, fdi, sl, side ] if sl
      end

      # 2) a later day in the same cycle: the earliest such day is also the
      #    best because every stream day carries the same slot mask and its
      #    earliest slot is constant
      #
      if d = next_set_bit(daymask, fdi + 1)
        return [ d - fdi, 0, d, first_slot, side ]
      end

      # 3) wrap into the next 400-year cycle
      #
      d2 = next_set_bit(daymask, 0)

      return nil unless d2

      [ CYCLE_DAYS - fdi + d2, 1, d2, first_slot, side ]
    end

    def next_set_bit(mask, from_index)

      shifted = mask >> from_index

      return nil if shifted == 0

      from_index + trailing_zeros(shifted)
    end

    def lowest_set_bit(mask)

      trailing_zeros(mask)
    end

    def trailing_zeros(i)

      (i & -i).bit_length - 1
    end

    def mod(a, b)

      ((a % b) + b) % b
    end

    def floor_second(t)

      f = t.to_f
      (f == f.to_i) ? t : ::EtOrbi::EoTime.new(f.to_i, t.zone)
    end

    # Howard Hinnant's proleptic-Gregorian civil <-> days algorithms
    # (http://howardhinnant.github.io/date_algorithms.html), days are
    # counted from 1970-01-01.
    #
    def abs_day_index(year, month, day)

      y = year - (month <= 2 ? 1 : 0)
      era = (y >= 0 ? y : y - 399) / 400
      yoe = y - era * 400
      mp = month + (month > 2 ? -3 : 9)
      doy = (153 * mp + 2) / 5 + day - 1
      doe = yoe * 365 + yoe / 4 - yoe / 100 + doy

      era * 146097 + doe - 719468
    end

    def civil_from_abs(z)

      z += 719468
      era = (z >= 0 ? z : z - 146096) / 146097
      doe = z - era * 146097
      yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
      y = yoe + era * 400
      doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
      mp = (5 * doy + 2) / 153
      d = doy - (153 * mp + 2) / 5 + 1
      m = mp + (mp < 10 ? 3 : -9)

      [ y + (m <= 2 ? 1 : 0), m, d ]
    end

    # Precomputed, for every month of the 400-year cycle, its length, the
    # wday of its first day, and its month number (1..12).
    #
    def calendar

      self.class.calendar
    end

    def self.calendar

      @calendar ||= build_calendar
    end

    DIMS = [ nil, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 ].freeze

    def self.build_calendar

      months = []
      wday = 6 # 2000-01-01 is a Saturday

      CYCLE_YEARS.times do |yi|
        (1..12).each do |mo|

          leap = (yi % 4 == 0 && yi % 100 != 0) || yi % 400 == 0
          len = (mo == 2 && leap) ? 29 : DIMS[mo]

          months << [ len, wday, mo ]

          wday = (wday + len) % 7
        end
      end

      months
    end
  end

  module_function

  # Compare two crons (strings or Fugit::Cron).
  # See Fugit::CronRelation for the shape of the result.
  #
  def cron_relation(a, b, from=::EtOrbi::EoTime.now)

    ::Fugit::CronRelation.analyze(a, b, from)
  end

  class Cron

    # Compare self with another cron, from the given point in time onward.
    #
    def relation_to(other, from=::EtOrbi::EoTime.now)

      ::Fugit::CronRelation.analyze(self, other, from)
    end
  end
end
