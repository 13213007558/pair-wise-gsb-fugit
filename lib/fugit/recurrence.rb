# frozen_string_literal: true

module Fugit

  # An anchored sequence of points in time, separated by a calendar
  # duration.
  #
  # Unlike repeatedly adding a Fugit::Duration to its own result (which
  # lets an adjusted date, like a February 28th clamped down from a
  # January 31st, become the new anchor and drift), a Recurrence keeps
  # its original anchor and computes every occurrence directly from it:
  #
  #   rec = Fugit::Recurrence.new('1M', '2024-01-31 09:00', overflow: :clamp)
  #   rec.at(1)  # 2024-02-29 09:00 (leap year, clamped to end of month)
  #   rec.at(2)  # 2024-03-31 09:00 (back to the 31st, no drift)
  #   rec.at(12) # 2025-01-31 09:00 (next year, anchor day preserved)
  #   rec.at(-1) # 2023-12-31 09:00 (negative indices walk backwards)
  #
  # Years and months advance by calendar; weeks, days, hours, minutes and
  # seconds are added as absolute amounts of seconds, following the
  # Fugit::Duration#add_to_time convention.
  #
  # When the anchor day of month does not exist in a target month
  # (e.g. the 31st in February), the +overflow+ strategy picked at
  # initialization applies:
  #
  #   :clamp  clamp down to the last day of the month
  #   :skip   the occurrence does not exist, indices skip over it
  #   :raise  a Fugit::Recurrence::OverflowError is raised
  #
  class Recurrence

    class OverflowError < ::StandardError; end

    OVERFLOW_STRATEGIES = %i[ clamp skip raise ].freeze

    # Months in the duration are calendar-shifted, the rest is added
    # as absolute seconds (same convention as Fugit::Duration#add_to_time)
    #
    SECOND_KEYS = %i[ wee day hou min sec ].freeze

    attr_reader :duration, :anchor, :overflow

    def initialize(duration, anchor, overflow:)

      @duration = Fugit::Duration.do_parse(duration)
      @anchor = ::EtOrbi.make_time(anchor)

      @overflow = overflow.to_sym rescue nil
      unless OVERFLOW_STRATEGIES.include?(@overflow)
        fail ArgumentError.new(
          "unknown overflow strategy #{overflow.inspect}, " +
          "expected one of #{OVERFLOW_STRATEGIES.inspect}")
      end

      h = @duration.h

      @months_step = (h[:yea] || 0) * 12 + (h[:mon] || 0)
      @seconds_step =
        SECOND_KEYS.inject(0) { |s, k|
          v = h[k]; v ? s + v * Fugit::Duration::KEYS[k][:s] : s }

      if @months_step < 0 || @seconds_step < 0 ||
         (@months_step == 0 && @seconds_step == 0)
        fail ArgumentError.new(
          "not a positive recurrence duration #{duration.inspect}")
      end
    end

    # Returns the n-th occurrence, computed directly from the anchor.
    #
    # n == 0 is the anchor itself, positive n walks forward, negative n
    # walks backwards. With the :skip strategy, n counts existing
    # occurrences only (overflowing months are not counted).
    #
    def at(n)

      n = Integer(n)

      return candidate(n) unless @overflow == :skip
      return @anchor if n == 0

      step = n > 0 ? 1 : -1
      k = 0
      remaining = n.abs

      loop do
        k += step
        t = candidate(k)
        next unless t
        remaining -= 1
        return t if remaining == 0
      end
    end
    alias [] at

    # Returns the first occurrence strictly after +from+.
    #
    def next_time(from=::EtOrbi::EoTime.now)

      from = ::EtOrbi.make_time(from)

      n = estimate_index(from)
      n += 1 while at(n) <= from
      n -= 1 while at(n - 1) > from

      at(n)
    end

    # Returns the last occurrence strictly before +from+.
    #
    def previous_time(from=::EtOrbi::EoTime.now)

      from = ::EtOrbi.make_time(from)

      n = estimate_index(from)
      n -= 1 while at(n) >= from
      n += 1 while at(n + 1) < from

      at(n)
    end

    def to_s

      "#{@duration.to_plain_s} from #{Fugit.time_to_zone_s(@anchor)}" +
        " (overflow: #{@overflow})"
    end

    protected

    # The k-th candidate, computed from the original anchor (never from
    # a previously adjusted occurrence). Returns nil for overflowing
    # months under the :skip strategy.
    #
    def candidate(k)

      t = shift_months(@anchor, k * @months_step)

      t = t + k * @seconds_step if t && @seconds_step != 0

      t
    end

    # Shifts the year and month of t by +months+ calendar months,
    # keeping the day of month and the time of day. When the day of
    # month does not exist in the target month, the overflow strategy
    # applies.
    #
    def shift_months(t, months)

      return t if months == 0

      y, m = (t.year * 12 + t.month - 1 + months).divmod(12)
      m += 1
      d = t.day

      last = last_day_of_month(y, m)

      if d > last
        case @overflow
        when :clamp then d = last
        when :skip then return nil
        else fail OverflowError.new(
          "no day #{t.day} in #{format('%04d-%02d', y, m)} " +
          "for recurrence anchored at #{Fugit.time_to_zone_s(@anchor)}")
        end
      end

      ::EtOrbi.make_time([ y, m, d, t.hour, t.min, t.sec ], t.zone)
    end

    def last_day_of_month(y, m)

      ::Date.new(y, m, -1).day
    end

    # Rough index of the occurrence at or before t, used as a starting
    # point for #next_time / #previous_time scans.
    #
    def estimate_index(t)

      if @months_step > 0
        dm = (t.year - @anchor.year) * 12 + (t.month - @anchor.month)
        dm -= 1 if t.day < @anchor.day
        dm / @months_step
      else
        ((t - @anchor) / @seconds_step).floor
      end
    end
  end
end
