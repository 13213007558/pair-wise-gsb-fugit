# frozen_string_literal: true

class Fugit::Duration

  # A sequence of points in time built by applying a duration
  # repeatedly to an "anchor" time.
  #
  # Years and months are advanced calendar-wise, while the day of the
  # month stays anchored to the day of the original anchor time.
  # Whenever the target month is shorter and the anchored day does not
  # exist in it, the +on_overflow+ strategy (which has to be chosen
  # explicitly) decides what happens:
  #
  #   :clamp  # the occurrence is clamped to the last day of the month
  #   :skip   # the occurrence is skipped (#at returns nil for it)
  #   :fail   # an ArgumentError is raised
  #
  # Weeks, days, hours, minutes and seconds are added as absolute
  # seconds, exactly like Fugit::Duration#add_to_time does.
  #
  # Each occurrence is computed directly from the original anchor,
  # never by accumulating previously computed (and potentially
  # adjusted) occurrences. Iterating with #each or #next_time thus
  # yields exactly the same points in time as direct #at(n) lookups,
  # and the anchored day does not drift as years go by.
  #
  #   seq = Fugit::Duration.parse('1M')
  #     .sequence('2024-01-31 09:00 UTC', on_overflow: :clamp)
  #
  #   seq.at(1)   # ==> 2024-02-29 09:00 UTC
  #   seq.at(12)  # ==> 2025-01-31 09:00 UTC (no drift)
  #   seq.at(-1)  # ==> 2023-12-31 09:00 UTC
  #
  class Sequence

    include Enumerable

    OVERFLOW_STRATEGIES = [ :clamp, :skip, :fail ].freeze

    # Average month length in seconds (Gregorian 400 year cycle),
    # only used to estimate occurrence indices when looking
    # occurrences up by point in time.
    #
    AVG_MONTH_S = 365.2425 * 24 * 3600 / 12

    # Bound for the scans looking for the next or previous
    # non-skipped occurrence (400 years worth of months, a full
    # Gregorian cycle).
    #
    SCAN_LIMIT = 4800

    attr_reader :duration, :anchor, :on_overflow

    def initialize(duration, anchor, on_overflow:)

      @duration = Fugit::Duration.do_parse(duration)
      @anchor = ::EtOrbi.make_time(anchor)
      @on_overflow = on_overflow

      fail ArgumentError.new(
        "unknown on_overflow strategy #{on_overflow.inspect}, " +
        "valid ones are #{OVERFLOW_STRATEGIES.inspect}"
      ) unless OVERFLOW_STRATEGIES.include?(@on_overflow)

      h = @duration.h

      @months = (h[:yea] || 0) * 12 + (h[:mon] || 0)
      @seconds = INFLA_KEYS.inject(0) { |s, (k, a)|
        v = h[k]; v ? s + v * a[:s] : s }

      fail ArgumentError.new(
        'cannot build a sequence out of a zero duration'
      ) if @months == 0 && @seconds == 0

      fail ArgumentError.new(
        'cannot build a sequence out of a duration mixing ' +
        "positive and negative components (#{@duration.to_plain_s})"
      ) if @months * @seconds < 0

      @direction = (@months != 0 ? @months : @seconds) <=> 0

      @anchor_hms = [ @anchor.hour, @anchor.min, @anchor.sec ]
      @anchor_subsec = @anchor.to_f % 1
    end

    # Returns the n-th occurrence of this sequence, an EtOrbi::EoTime
    # instance, or nil when the occurrence overflows a short month and
    # the strategy is :skip.
    #
    # n may be negative, counting occurrences before the anchor.
    #
    def at(n)

      unless n.is_a?(Integer)
        fail ArgumentError.new(
          "occurrence index #{n.inspect} is not an Integer")
      end

      t = _calendar_time_at(n)

      t && t + n * @seconds
    end
    alias [] at

    # Returns the first occurrence strictly after the given point
    # in time, or nil when there is none within SCAN_LIMIT steps.
    #
    def next_time(from=::EtOrbi::EoTime.now)

      j = _next_index(::EtOrbi.make_time(from))

      j && _g(j)
    end

    # Returns the last occurrence strictly before the given point
    # in time, or nil when there is none within SCAN_LIMIT steps.
    #
    def previous_time(from=::EtOrbi::EoTime.now)

      j = _previous_index(::EtOrbi.make_time(from))

      j && _g(j)
    end

    # Yields occurrences, starting with the anchor (index 0) and
    # following the duration direction. Skipped occurrences (strategy
    # :skip) are not yielded. The sequence is infinite, use #lazy or
    # #first to pick a finite number of occurrences.
    #
    def each

      return enum_for(:each) unless block_given?

      k = 0
      loop do
        o = at(k)
        yield o if o
        k += 1
      end
    end

    def to_s

      "every #{@duration.to_plain_s} from #{@anchor.to_s} " +
      "(on_overflow: #{@on_overflow})"
    end
    alias inspect to_s

    protected

    # g(j) == at(direction * j) is strictly increasing in j,
    # whatever the direction of the duration is.
    #
    def _g(j); at(@direction * j); end

    # The calendar (year and month) part of the n-th occurrence,
    # as an EtOrbi::EoTime, or nil when the occurrence overflows
    # and the strategy is :skip.
    #
    def _calendar_time_at(n)

      mi = @anchor.year * 12 + (@anchor.month - 1) + n * @months
      y, m = mi.divmod(12)
      m += 1

      d = @anchor.day
      ld = ::Date.new(y, m, -1).day

      if d > ld
        case @on_overflow
        when :clamp then d = ld
        when :skip then return nil
        else fail ArgumentError.new(
          "occurrence #{n} (#{@duration.to_plain_s} from #{@anchor.to_s}) " +
          "overflows: #{format('%04d-%02d', y, m)} has no day #{d}")
        end
      end

      ::EtOrbi.make_time(
        [ y, m, d ] + @anchor_hms,
        @anchor.zone
      ) + @anchor_subsec
    end

    def _estimate_index(t)

      avg = @months.abs * AVG_MONTH_S + @seconds.abs

      ((t.to_f - @anchor.to_f) / avg).round
    end

    # Returns the smallest j where g(j) is not nil and g(j) > t,
    # or nil when there is no such j within SCAN_LIMIT.
    #
    def _next_index(t)

      j = _estimate_index(t)

      SCAN_LIMIT.times do
        o = _g(j - 1)
        break if o && o <= t
        j -= 1
      end

      SCAN_LIMIT.times do
        o = _g(j)
        return j if o && o > t
        j += 1
      end

      nil
    end

    # Returns the largest j where g(j) is not nil and g(j) < t,
    # or nil when there is no such j within SCAN_LIMIT.
    #
    def _previous_index(t)

      j = _estimate_index(t)

      SCAN_LIMIT.times do
        o = _g(j + 1)
        break if o && o >= t
        j += 1
      end

      SCAN_LIMIT.times do
        o = _g(j)
        return j if o && o < t
        j -= 1
      end

      nil
    end
  end
end
