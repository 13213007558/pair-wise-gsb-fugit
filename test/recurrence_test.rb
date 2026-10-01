#
# Specifying fugit
#
# Wed Oct  1 00:00:00 JST 2026
#


group Fugit::Recurrence do

  ss = lambda { |t| t.strftime('%Y-%m-%d %H:%M:%S') }

  group '#initialize' do

    test 'rejects an unknown overflow strategy' do

      assert_error(
        lambda { Fugit::Recurrence.new('1M', '2024-01-31', overflow: :nada) },
        ArgumentError,
        'unknown overflow strategy :nada, expected one of [:clamp, :skip, :raise]')
    end

    test 'requires an overflow strategy' do

      assert_error(
        lambda { Fugit::Recurrence.new('1M', '2024-01-31') },
        ArgumentError)
    end

    test 'rejects a zero duration' do

      assert_error(
        lambda { Fugit::Recurrence.new('0s', '2024-01-31', overflow: :clamp) },
        ArgumentError,
        'not a positive recurrence duration "0s"')
    end

    test 'rejects a negative duration' do

      assert_error(
        lambda {
          Fugit::Recurrence.new('P-1M', '2024-01-31', overflow: :clamp)
        },
        ArgumentError,
        'not a positive recurrence duration "P-1M"')
    end
  end

  group 'monthly from 2024-01-31 09:00 UTC' do

    group 'overflow: :clamp' do

      rec =
        Fugit::Recurrence.new(
          '1M', '2024-01-31 09:00:00 UTC', overflow: :clamp)

      {
        0 => '2024-01-31 09:00:00',
        1 => '2024-02-29 09:00:00', # leap year, clamped to end of month
        2 => '2024-03-31 09:00:00', # back to the 31st, no drift
        3 => '2024-04-30 09:00:00',
        11 => '2024-12-31 09:00:00',
        12 => '2025-01-31 09:00:00', # next year, anchor day preserved
        13 => '2025-02-28 09:00:00',
        14 => '2025-03-31 09:00:00',
        24 => '2026-01-31 09:00:00',
        -1 => '2023-12-31 09:00:00',
        -2 => '2023-11-30 09:00:00',
        -11 => '2023-02-28 09:00:00',
        -12 => '2023-01-31 09:00:00',
        -13 => '2022-12-31 09:00:00',
      }.each do |n, target|

        test "at(#{n}) is #{target}" do

          assert ss.(rec.at(n)), target
          assert ss.(rec[n]), target
        end
      end
    end

    group 'overflow: :skip' do

      rec =
        Fugit::Recurrence.new(
          '1M', '2024-01-31 09:00:00 UTC', overflow: :skip)

      {
        0 => '2024-01-31 09:00:00',
        1 => '2024-03-31 09:00:00', # February is skipped
        2 => '2024-05-31 09:00:00',
        3 => '2024-07-31 09:00:00',
        4 => '2024-08-31 09:00:00',
        5 => '2024-10-31 09:00:00',
        6 => '2024-12-31 09:00:00',
        7 => '2025-01-31 09:00:00', # next year, anchor day preserved
        -1 => '2023-12-31 09:00:00',
        -2 => '2023-10-31 09:00:00',
        -3 => '2023-08-31 09:00:00',
        -7 => '2023-01-31 09:00:00',
      }.each do |n, target|

        test "at(#{n}) is #{target}" do

          assert ss.(rec.at(n)), target
        end
      end
    end

    group 'overflow: :raise' do

      rec =
        Fugit::Recurrence.new(
          '1M', '2024-01-31 09:00:00 UTC', overflow: :raise)

      test 'at(2) is 2024-03-31 09:00:00' do

        assert ss.(rec.at(2)), '2024-03-31 09:00:00'
      end

      test 'at(1) raises an OverflowError' do

        assert_error(
          lambda { rec.at(1) },
          Fugit::Recurrence::OverflowError,
          'no day 31 in 2024-02 for recurrence anchored at ' +
            '2024-01-31 09:00:00 UTC Z')
      end

      test 'at(-11) raises an OverflowError' do

        assert_error(
          lambda { rec.at(-11) },
          Fugit::Recurrence::OverflowError,
          'no day 31 in 2023-02 for recurrence anchored at ' +
            '2024-01-31 09:00:00 UTC Z')
      end
    end
  end

  group 'yearly from leap day 2024-02-29 10:00 UTC' do

    group 'overflow: :clamp' do

      rec =
        Fugit::Recurrence.new(
          '1y', '2024-02-29 10:00:00 UTC', overflow: :clamp)

      {
        1 => '2025-02-28 10:00:00',
        2 => '2026-02-28 10:00:00',
        4 => '2028-02-29 10:00:00', # next leap year, back to the 29th
        -1 => '2023-02-28 10:00:00',
        -4 => '2020-02-29 10:00:00',
      }.each do |n, target|

        test "at(#{n}) is #{target}" do

          assert ss.(rec.at(n)), target
        end
      end
    end

    group 'overflow: :skip' do

      rec =
        Fugit::Recurrence.new(
          '1y', '2024-02-29 10:00:00 UTC', overflow: :skip)

      test 'at(1) is 2028-02-29 10:00:00' do

        assert ss.(rec.at(1)), '2028-02-29 10:00:00'
      end

      test 'at(-1) is 2020-02-29 10:00:00' do

        assert ss.(rec.at(-1)), '2020-02-29 10:00:00'
      end
    end

    group 'overflow: :raise' do

      rec =
        Fugit::Recurrence.new(
          '1y', '2024-02-29 10:00:00 UTC', overflow: :raise)

      test 'at(1) raises an OverflowError' do

        assert_error(
          lambda { rec.at(1) },
          Fugit::Recurrence::OverflowError,
          'no day 29 in 2025-02 for recurrence anchored at ' +
            '2024-02-29 10:00:00 UTC Z')
      end

      test 'at(4) is 2028-02-29 10:00:00' do

        assert ss.(rec.at(4)), '2028-02-29 10:00:00'
      end
    end
  end

  group 'quarterly from 2024-01-31 09:00 UTC' do

    rec =
      Fugit::Recurrence.new(
        '3M', '2024-01-31 09:00:00 UTC', overflow: :clamp)

    {
      1 => '2024-04-30 09:00:00',
      2 => '2024-07-31 09:00:00',
      3 => '2024-10-31 09:00:00',
      4 => '2025-01-31 09:00:00', # next year, anchor day preserved
    }.each do |n, target|

      test "at(#{n}) is #{target}" do

        assert ss.(rec.at(n)), target
      end
    end
  end

  group 'time of day' do

    test 'is preserved across calendar shifts' do

      rec =
        Fugit::Recurrence.new(
          '1M', '2024-01-31 09:30:15 UTC', overflow: :clamp)

      assert ss.(rec.at(2)), '2024-03-31 09:30:15'
      assert ss.(rec.at(-1)), '2023-12-31 09:30:15'
    end

    test 'hours in the duration are added as absolute seconds' do

      rec =
        Fugit::Recurrence.new(
          '1M 6h', '2024-01-31 09:30:15 UTC', overflow: :clamp)

      assert ss.(rec.at(1)), '2024-02-29 15:30:15'
    end

    test 'a seconds-only duration walks plain seconds' do

      rec =
        Fugit::Recurrence.new(
          '12h', '2024-01-31 09:30:15 UTC', overflow: :clamp)

      assert ss.(rec.at(2)), '2024-02-01 09:30:15'
      assert ss.(rec.at(-1)), '2024-01-30 21:30:15'
    end
  end

  group '#next_time' do

    test 'returns the first occurrence strictly after from' do

      rec =
        Fugit::Recurrence.new(
          '1M', '2024-01-31 09:00:00 UTC', overflow: :clamp)

      assert ss.(rec.next_time(rec.anchor)), '2024-02-29 09:00:00'
      assert(
        ss.(rec.next_time(EtOrbi.make_time('2024-02-15 00:00:00 UTC'))),
        '2024-02-29 09:00:00')
      assert(
        ss.(rec.next_time(EtOrbi.make_time('2024-02-29 09:00:00 UTC'))),
        '2024-03-31 09:00:00')
    end

    test 'consecutive evaluation matches direct at(n) computation' do

      rec =
        Fugit::Recurrence.new(
          '1M', '2024-01-31 09:00:00 UTC', overflow: :clamp)

      t = rec.anchor
      (1..26).each do |n|
        t = rec.next_time(t)
        assert ss.(t), ss.(rec.at(n))
      end
    end

    test 'consecutive evaluation matches at(n) with overflow: :skip' do

      rec =
        Fugit::Recurrence.new(
          '1M', '2024-01-31 09:00:00 UTC', overflow: :skip)

      t = rec.anchor
      (1..14).each do |n|
        t = rec.next_time(t)
        assert ss.(t), ss.(rec.at(n))
      end
    end
  end

  group '#previous_time' do

    test 'returns the last occurrence strictly before from' do

      rec =
        Fugit::Recurrence.new(
          '1M', '2024-01-31 09:00:00 UTC', overflow: :clamp)

      assert ss.(rec.previous_time(rec.anchor)), '2023-12-31 09:00:00'
      assert(
        ss.(rec.previous_time(EtOrbi.make_time('2024-03-31 09:00:00 UTC'))),
        '2024-02-29 09:00:00')
    end

    test 'consecutive evaluation matches direct at(-n) computation' do

      rec =
        Fugit::Recurrence.new(
          '1M', '2024-01-31 09:00:00 UTC', overflow: :clamp)

      t = rec.anchor
      (1..14).each do |n|
        t = rec.previous_time(t)
        assert ss.(t), ss.(rec.at(-n))
      end
    end
  end

  group 'time zone' do

    test 'keeps the anchor zone' do

      rec =
        Fugit::Recurrence.new(
          '1M', '2024-01-31 09:00:00 Asia/Tokyo', overflow: :clamp)

      t = rec.at(1)

      assert t.zone.name, 'Asia/Tokyo'
      assert ss.(t), '2024-02-29 09:00:00'
    end
  end
end
