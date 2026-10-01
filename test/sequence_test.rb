#
# Specifying fugit
#
# Wed Oct  1 2026  Ishinomaki
#


group Fugit::Duration::Sequence do

  dseq = lambda do |d, anchor, on_overflow|
    Fugit::Duration.parse(d).sequence(anchor, on_overflow: on_overflow)
  end

  group '.new' do

    test 'requires an explicit on_overflow strategy' do

      assert_error(
        lambda { Fugit::Duration.parse('1M').sequence('2024-01-31') },
        ArgumentError)
    end

    test 'rejects an unknown on_overflow strategy' do

      assert_error(
        lambda { dseq.('1M', '2024-01-31', :nope) },
        ArgumentError,
        'unknown on_overflow strategy :nope, ' +
        'valid ones are [:clamp, :skip, :fail]')
    end

    test 'rejects a zero duration' do

      assert_error(
        lambda { dseq.('0s', '2024-01-31', :clamp) },
        ArgumentError,
        'cannot build a sequence out of a zero duration')
    end

    test 'rejects a duration mixing positive and negative components' do

      assert_error(
        lambda { dseq.('1M -40d', '2024-01-31', :clamp) },
        ArgumentError,
        'cannot build a sequence out of a duration mixing ' +
        'positive and negative components (1M-40D)')
    end

    test 'exposes its duration, anchor and strategy' do

      s = dseq.('1M', '2024-01-31 09:00:00 UTC', :clamp)

      assert s.duration, Fugit::Duration.parse('1M')
      assert s.anchor.to_s, '2024-01-31 09:00:00 Z'
      assert s.on_overflow, :clamp
    end
  end

  group '#at' do

    test 'returns the anchor for index 0' do

      s = dseq.('1M', '2024-01-31 09:00:00 UTC', :clamp)

      assert s.at(0).to_s, '2024-01-31 09:00:00 Z'
    end

    test 'rejects a non-integer index' do

      s = dseq.('1M', '2024-01-31', :clamp)

      assert_error(
        lambda { s.at(1.5) },
        ArgumentError,
        'occurrence index 1.5 is not an Integer')
    end

    test 'is aliased as #[]' do

      s = dseq.('1M', '2024-01-31 09:00:00 UTC', :clamp)

      assert s[1].to_s, '2024-02-29 09:00:00 Z'
    end

    group 'Jan 31st monthly anchor' do

      test 'clamps to the end of short months' do

        s = dseq.('1M', '2024-01-31 09:00:00 UTC', :clamp)

        assert s.at(1).to_s, '2024-02-29 09:00:00 Z'
        assert s.at(2).to_s, '2024-03-31 09:00:00 Z'
        assert s.at(3).to_s, '2024-04-30 09:00:00 Z'
      end

      test 'does not drift the next year' do

        s = dseq.('1M', '2024-01-31 09:00:00 UTC', :clamp)

        assert s.at(12).to_s, '2025-01-31 09:00:00 Z'
        assert s.at(13).to_s, '2025-02-28 09:00:00 Z'
        assert s.at(14).to_s, '2025-03-31 09:00:00 Z'
        assert s.at(24).to_s, '2026-01-31 09:00:00 Z'
      end

      test 'skips short months when the strategy is :skip' do

        s = dseq.('1M', '2024-01-31 09:00:00 UTC', :skip)

        assert_nil s.at(1)
        assert s.at(2).to_s, '2024-03-31 09:00:00 Z'
        assert_nil s.at(3)
        assert s.at(4).to_s, '2024-05-31 09:00:00 Z'
      end

      test 'fails on short months when the strategy is :fail' do

        s = dseq.('1M', '2024-01-31 09:00:00 UTC', :fail)

        assert_error(
          lambda { s.at(1) },
          ArgumentError,
          'occurrence 1 (1M from 2024-01-31 09:00:00 Z) overflows: ' +
          '2024-02 has no day 31')

        assert s.at(2).to_s, '2024-03-31 09:00:00 Z'
      end
    end

    group 'Feb 29th leap year anchor' do

      test 'clamps to Feb 28th on non-leap years' do

        s = dseq.('1y', '2024-02-29 10:00:00 UTC', :clamp)

        assert s.at(1).to_s, '2025-02-28 10:00:00 Z'
        assert s.at(2).to_s, '2026-02-28 10:00:00 Z'
        assert s.at(3).to_s, '2027-02-28 10:00:00 Z'
      end

      test 'lands on Feb 29th again on leap years' do

        s = dseq.('1y', '2024-02-29 10:00:00 UTC', :clamp)

        assert s.at(4).to_s, '2028-02-29 10:00:00 Z'
        assert s.at(8).to_s, '2032-02-29 10:00:00 Z'
      end

      test 'skips non-leap years when the strategy is :skip' do

        s = dseq.('1y', '2024-02-29 10:00:00 UTC', :skip)

        assert_nil s.at(1)
        assert_nil s.at(2)
        assert_nil s.at(3)
        assert s.at(4).to_s, '2028-02-29 10:00:00 Z'
      end

      test 'fails on non-leap years when the strategy is :fail' do

        s = dseq.('1y', '2024-02-29 10:00:00 UTC', :fail)

        assert_error(
          lambda { s.at(1) },
          ArgumentError,
          'occurrence 1 (1Y from 2024-02-29 10:00:00 Z) overflows: ' +
          '2025-02 has no day 29')
      end
    end

    group 'negative indices' do

      test 'counts backwards from the anchor' do

        s = dseq.('1M', '2024-01-31 09:00:00 UTC', :clamp)

        assert s.at(-1).to_s, '2023-12-31 09:00:00 Z'
        assert s.at(-2).to_s, '2023-11-30 09:00:00 Z'
        assert s.at(-10).to_s, '2023-03-31 09:00:00 Z'
        assert s.at(-11).to_s, '2023-02-28 09:00:00 Z'
        assert s.at(-12).to_s, '2023-01-31 09:00:00 Z'
      end

      test 'counts backwards over leap years' do

        s = dseq.('1y', '2024-02-29 10:00:00 UTC', :clamp)

        assert s.at(-1).to_s, '2023-02-28 10:00:00 Z'
        assert s.at(-4).to_s, '2020-02-29 10:00:00 Z'
        assert s.at(-8).to_s, '2016-02-29 10:00:00 Z'
      end

      test 'skips backwards when the strategy is :skip' do

        s = dseq.('1y', '2024-02-29 10:00:00 UTC', :skip)

        assert_nil s.at(-1)
        assert s.at(-4).to_s, '2020-02-29 10:00:00 Z'
      end
    end

    group 'time of day' do

      test 'adds hours, minutes and seconds as absolute seconds' do

        s = dseq.('1M2h30m', '2024-01-31 10:00:00 UTC', :clamp)

        assert s.at(1).to_s, '2024-02-29 12:30:00 Z'
        assert s.at(2).to_s, '2024-03-31 15:00:00 Z'
        assert s.at(-1).to_s, '2023-12-31 07:30:00 Z'
      end

      test 'supports durations without years and months' do

        s = dseq.('12h', '2024-01-31 10:00:00 UTC', :clamp)

        assert s.at(1).to_s, '2024-01-31 22:00:00 Z'
        assert s.at(2).to_s, '2024-02-01 10:00:00 Z'
        assert s.at(-1).to_s, '2024-01-30 22:00:00 Z'
      end

      test 'keeps the timezone of the anchor' do

        s = dseq.('1M', '2024-01-31 09:00:00 Asia/Tokyo', :clamp)

        assert s.at(1).to_s, '2024-02-29 09:00:00 +0900'
      end
    end

    group 'negative durations' do

      test 'steps backwards for positive indices' do

        s = dseq.('-1M', '2024-03-31 09:00:00 UTC', :clamp)

        assert s.at(1).to_s, '2024-02-29 09:00:00 Z'
        assert s.at(2).to_s, '2024-01-31 09:00:00 Z'
        assert s.at(-1).to_s, '2024-04-30 09:00:00 Z'
      end
    end
  end

  group '#next_time' do

    test 'returns the first occurrence strictly after the given time' do

      s = dseq.('1M', '2024-01-31 09:00:00 UTC', :clamp)

      assert s.next_time('2024-02-15 00:00:00 UTC').to_s,
        '2024-02-29 09:00:00 Z'
      assert s.next_time('2024-01-31 09:00:00 UTC').to_s,
        '2024-02-29 09:00:00 Z'
    end

    test 'skips over skipped occurrences' do

      s = dseq.('1M', '2024-01-31 09:00:00 UTC', :skip)

      assert s.next_time('2024-02-15 00:00:00 UTC').to_s,
        '2024-03-31 09:00:00 Z'
    end

    test 'skips over non-leap years' do

      s = dseq.('1y', '2024-02-29 10:00:00 UTC', :skip)

      assert s.next_time('2025-01-01 00:00:00 UTC').to_s,
        '2028-02-29 10:00:00 Z'
    end

    test 'finds occurrences far in the future' do

      s = dseq.('1M', '2024-01-31 09:00:00 UTC', :clamp)

      assert s.next_time('2030-06-01 00:00:00 UTC').to_s,
        '2030-06-30 09:00:00 Z'
    end

    test 'finds occurrences before the anchor' do

      s = dseq.('1M', '2024-01-31 09:00:00 UTC', :clamp)

      assert s.next_time('2023-02-15 00:00:00 UTC').to_s,
        '2023-02-28 09:00:00 Z'
    end

    test 'works with negative durations' do

      s = dseq.('-1M', '2024-03-31 09:00:00 UTC', :clamp)

      assert s.next_time('2024-03-01 00:00:00 UTC').to_s,
        '2024-03-31 09:00:00 Z'
    end
  end

  group '#previous_time' do

    test 'returns the last occurrence strictly before the given time' do

      s = dseq.('1M', '2024-01-31 09:00:00 UTC', :clamp)

      assert s.previous_time('2024-02-15 00:00:00 UTC').to_s,
        '2024-01-31 09:00:00 Z'
      assert s.previous_time('2024-01-31 09:00:00 UTC').to_s,
        '2023-12-31 09:00:00 Z'
    end

    test 'skips over skipped occurrences' do

      s = dseq.('1M', '2024-01-31 09:00:00 UTC', :skip)

      assert s.previous_time('2024-03-15 00:00:00 UTC').to_s,
        '2024-01-31 09:00:00 Z'
    end

    test 'skips over non-leap years' do

      s = dseq.('1y', '2024-02-29 10:00:00 UTC', :skip)

      assert s.previous_time('2028-01-01 00:00:00 UTC').to_s,
        '2024-02-29 10:00:00 Z'
    end

    test 'finds occurrences far in the future' do

      s = dseq.('1M', '2024-01-31 09:00:00 UTC', :clamp)

      assert s.previous_time('2030-06-01 00:00:00 UTC').to_s,
        '2030-05-31 09:00:00 Z'
    end

    test 'works with negative durations' do

      s = dseq.('-1M', '2024-03-31 09:00:00 UTC', :clamp)

      assert s.previous_time('2024-03-01 00:00:00 UTC').to_s,
        '2024-02-29 09:00:00 Z'
    end
  end

  group '#each' do

    test 'yields occurrences starting with the anchor' do

      s = dseq.('1M', '2024-01-31 09:00:00 UTC', :clamp)

      assert s.first(4).collect(&:to_s), [
        '2024-01-31 09:00:00 Z',
        '2024-02-29 09:00:00 Z',
        '2024-03-31 09:00:00 Z',
        '2024-04-30 09:00:00 Z' ]
    end

    test 'does not yield skipped occurrences' do

      s = dseq.('1M', '2024-01-31 09:00:00 UTC', :skip)

      assert s.first(4).collect(&:to_s), [
        '2024-01-31 09:00:00 Z',
        '2024-03-31 09:00:00 Z',
        '2024-05-31 09:00:00 Z',
        '2024-07-31 09:00:00 Z' ]
    end
  end

  group 'consistency' do

    test 'consecutive next_time evaluation matches direct #at(n)' do

      s = dseq.('1M', '2024-01-31 09:00:00 UTC', :clamp)

      t = s.at(0)
      12.times { t = s.next_time(t) }

      assert t.to_s, s.at(12).to_s
      assert t.to_s, '2025-01-31 09:00:00 Z'
    end

    test 'consecutive previous_time evaluation matches direct #at(-n)' do

      s = dseq.('1M', '2024-01-31 09:00:00 UTC', :clamp)

      t = s.at(0)
      12.times { t = s.previous_time(t) }

      assert t.to_s, s.at(-12).to_s
      assert t.to_s, '2023-01-31 09:00:00 Z'
    end

    test 'enumeration matches direct #at(n) lookups' do

      s = dseq.('1M', '2024-01-31 09:00:00 UTC', :clamp)

      assert(
        s.first(25).collect(&:to_s),
        (0..24).collect { |n| s.at(n).to_s })
    end

    test 'enumeration matches direct #at(n) lookups with :skip' do

      s = dseq.('1y', '2024-02-29 10:00:00 UTC', :skip)

      assert(
        s.first(4).collect(&:to_s),
        (0..12).collect { |n| s.at(n) }.compact.collect(&:to_s))
    end
  end
end
