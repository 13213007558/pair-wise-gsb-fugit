#
# Specifying fugit
#
# Wed Oct  1 00:00:00 UTC 2026
#

group Fugit::Cron do

  group '.relate' do


    group 'relation' do

      test 'is :equal for identical crons' do

        r = Fugit::Cron.relate('0 0 * * *', '0 0 * * *', '2026-10-01 00:00:00 UTC')

        assert r.relation, :equal
        assert r.equal?
        assert r.witness.nil?
        assert r.reason.nil?
      end

      test 'is :equal for equivalent crons (weekday hash vs day_and)' do

        # the 3rd Friday of a month always falls between the 15th and
        # the 21st, and a Friday between the 15th and the 21st is always
        # the 3rd one

        r = Fugit::Cron.relate('0 0 * * 5#3', '0 0 15-21 * 5&', '2026-10-01 00:00:00 UTC')

        assert r.relation, :equal
        assert r.witness.nil?
      end

      test 'is :equal for equivalent crons (last day forms)' do

        r = Fugit::Cron.relate('0 0 L * *', '0 0 last * *', '2026-10-01 00:00:00 UTC')

        assert r.relation, :equal
      end

      test 'is :subset when a triggers strictly less often than b' do

        r = Fugit::Cron.relate('0 0 * * 1', '0 0 * * 1,2')

        assert r.relation, :subset
        assert r.subset?
        assert r.witness.to_s, '2026-10-06 00:00:00 Z' # first Tuesday
        assert r.witness_cron, :b
      end

      test 'is :superset when a triggers strictly more often than b' do

        r = Fugit::Cron.relate('0 0 * * 1,2', '0 0 * * 1')

        assert r.relation, :superset
        assert r.superset?
        assert r.witness.to_s, '2026-10-06 00:00:00 Z'
        assert r.witness_cron, :a
      end

      test 'is :overlap when neither contains the other' do

        # the 1st of the month vs Mondays

        r = Fugit::Cron.relate('0 0 1 * *', '0 0 * * 1', '2026-10-01 00:00:00 UTC')

        assert r.relation, :overlap
        assert r.overlap?
        assert r.intersect?
        # 2026-10-01 is a Thursday, the 1st, a matches, b doesn't
        assert r.witness.to_s, '2026-10-01 00:00:00 Z'
        assert r.witness_cron, :a
      end

      test 'is :disjoint when the schedules never coincide' do

        r = Fugit::Cron.relate('0 0 * * 1', '0 0 * * 2', '2026-10-01 00:00:00 UTC')

        assert r.relation, :disjoint
        assert r.disjoint?
        assert r.witness.to_s, '2026-10-05 00:00:00 Z' # first Monday
        assert r.witness_cron, :a
      end

      test 'supports months' do

        r = Fugit::Cron.relate('0 0 * 6 *', '0 0 * * *', '2026-10-01 00:00:00 UTC')

        assert r.relation, :subset
        assert r.witness.to_s, '2026-10-01 00:00:00 Z'
        assert r.witness_cron, :b
      end

      test 'supports seconds' do

        r = Fugit::Cron.relate(
          '0 0 0 * * *', '30 0 0 * * *', '2026-10-01 00:00:01 UTC')

        assert r.relation, :disjoint
        assert r.witness.to_s, '2026-10-01 00:00:30 Z'
        assert r.witness_cron, :b
      end

      test 'supports L (last day of month)' do

        r = Fugit::Cron.relate('0 0 L * *', '0 0 28-31 * *', '2026-10-01 00:00:00 UTC')

        assert r.relation, :subset
        # 2026-10-28 is in 28-31 but is not the last day of October
        assert r.witness.to_s, '2026-10-28 00:00:00 Z'
        assert r.witness_cron, :b
      end

      test 'supports weekday #L (last weekday of month)' do

        r = Fugit::Cron.relate('0 0 * * 1#L', '0 0 * * 1', '2026-10-01 00:00:00 UTC')

        assert r.relation, :subset
        # 2026-10-05 is a Monday, but not the last one of October
        assert r.witness.to_s, '2026-10-05 00:00:00 Z'
        assert r.witness_cron, :b
      end

      test 'supports negative monthdays' do

        r = Fugit::Cron.relate('0 0 -2 * *', '0 0 -2,-1 * *')

        assert r.relation, :subset
        # 2026-10-31 is the last day of October
        assert r.witness.to_s, '2026-10-31 00:00:00 Z'
        assert r.witness_cron, :b
      end

      test 'the witness is matched by exactly one of the two crons' do

        [
          [ '0 0 * * 1', '0 0 * * 1,2' ],
          [ '0 0 1 * *', '0 0 * * 1' ],
          [ '0 0 * * 1', '0 0 * * 2' ],
          [ '0 0 L * *', '0 0 28-31 * *' ],
          [ '0 0 28,29 2 *', '0 0 28 2 *' ],
        ].each do |a, b|

          r = Fugit::Cron.relate(a, b, '2026-10-01 00:00:00 UTC')

          ca = Fugit::Cron.parse(a)
          cb = Fugit::Cron.parse(b)

          ma = ca.match?(r.witness)
          mb = cb.match?(r.witness)

          assert ma != mb, true
          assert r.witness_cron, ma ? :a : :b
        end
      end
    end

    group 'witness' do

      test 'is the earliest distinguishing time at or after from' do

        # from is exactly a trigger of a but not of b

        r = Fugit::Cron.relate('0 0 1 * *', '0 0 * * 1', '2026-10-01 00:00:00 UTC')

        assert r.witness.to_s, '2026-10-01 00:00:00 Z'
      end

      test 'skips times before from' do

        r = Fugit::Cron.relate('0 0 1 * *', '0 0 * * 1', '2026-10-01 00:00:01 UTC')

        # 2026-10-01 00:00:00 is before from, next is Monday 2026-10-05
        assert r.witness.to_s, '2026-10-05 00:00:00 Z'
        assert r.witness_cron, :b
      end

      test 'is nil when the crons are equivalent' do

        r = Fugit::Cron.relate('0 0 * * 5#3', '0 0 15-21 * 5&', '2026-10-01 00:00:00 UTC')

        assert r.witness.nil?
        assert r.witness_cron.nil?
      end
    end

    group 'leap years' do

      # These two crons only differ on February 29th, they only
      # differ in leap years.  A check "running" them over the next
      # year (or any window shorter than the distance to the next
      # Feb 29th) would wrongly conclude they are equivalent.

      A = '0 0 28,29 2 *'
      B = '0 0 28 2 *'

      test 'finds the Feb 29th witness almost 2 years away' do

        r = Fugit::Cron.relate(A, B, '2026-03-01 00:00:00 UTC')

        assert r.relation, :superset
        assert r.witness.to_s, '2028-02-29 00:00:00 Z'
        assert r.witness_cron, :a
      end

      test 'finds the same witness in the reverse direction' do

        r = Fugit::Cron.relate(B, A, '2026-03-01 00:00:00 UTC')

        assert r.relation, :subset
        assert r.witness.to_s, '2028-02-29 00:00:00 Z'
        assert r.witness_cron, :b
      end

      test 'finds no witness within a non-leap year' do

        # from 2027-03-01, the next difference is 2028-02-29,
        # more than 11 months away, outside of a "next year" window

        r = Fugit::Cron.relate(A, B, '2027-03-01 00:00:00 UTC')

        assert r.relation, :superset
        assert r.witness.to_s, '2028-02-29 00:00:00 Z'
      end

      test 'honours a from right before Feb 29th' do

        r = Fugit::Cron.relate(A, B, '2028-02-28 23:59:59 UTC')

        assert r.witness.to_s, '2028-02-29 00:00:00 Z'
      end

      test 'the witness is a Feb 29th matched by a only' do

        r = Fugit::Cron.relate(A, B, '2026-03-01 00:00:00 UTC')

        assert Fugit::Cron.parse(A).match?(r.witness), true
        assert Fugit::Cron.parse(B).match?(r.witness), false
        assert r.witness.month, 2
        assert r.witness.day, 29
      end

      test 'spans the 2100 leap year exception' do

        # 2100 is divisible by 100 but not by 400, it is not a leap
        # year, from 2097 on the next Feb 29th is in 2104, almost
        # 7 years away, far outside of any "trial" window

        r = Fugit::Cron.relate(A, B, '2097-03-01 00:00:00 UTC')

        assert r.relation, :superset
        assert r.witness.to_s, '2104-02-29 00:00:00 Z'
      end
    end

    group 'timezones' do

      test 'accepts UTC' do

        r = Fugit::Cron.relate('0 0 * * * UTC', '0 0 * * 1 UTC', '2026-10-01 00:00:00 UTC')

        assert r.relation, :superset
      end

      test 'accepts one and the same fixed offset timezone' do

        r = Fugit::Cron.relate('0 0 * * * +08:00', '0 0 * * 1 +08:00', '2026-10-01 00:00:00 UTC')

        assert r.relation, :superset
        # 2026-10-01 00:00:00 UTC is 08:00 +08:00, the next +08:00
        # midnight is 2026-10-02 00:00:00 +08:00, a Friday
        assert r.witness.to_s, '2026-10-01 16:00:00 Z'
        assert r.witness_cron, :a
      end

      test 'accepts equivalent offsets under different names' do

        r = Fugit::Cron.relate('0 0 * * * UTC', '0 0 * * 1 Etc/UTC', '2026-10-01 00:00:00 UTC')

        assert r.relation, :superset
      end

      test 'is :undecidable for a dynamic timezone' do

        r = Fugit::Cron.relate('0 0 * * * Asia/Shanghai', '0 0 * * *', '2026-10-01 00:00:00 UTC')

        assert r.relation, :undecidable
        assert r.reason, :dynamic_timezone
        assert r.undecidable?
        assert r.witness.nil?
      end

      test 'is :undecidable for two identical crons in a DST zone' do

        r = Fugit::Cron.relate('0 9 * * * Europe/Berlin', '0 9 * * * Europe/Berlin', '2026-10-01 00:00:00 UTC')

        assert r.relation, :undecidable
        assert r.reason, :dynamic_timezone
      end

      test 'is :undecidable when the zones conflict' do

        r = Fugit::Cron.relate('0 0 * * * +08:00', '0 0 * * * +09:00', '2026-10-01 00:00:00 UTC')

        assert r.relation, :undecidable
        assert r.reason, :conflicting_zones
      end

      test 'is :undecidable when from falls back to a dynamic zone' do

        r = Fugit::Cron.relate(
          '0 0 * * *', '0 0 * * 1', '2026-10-01 00:00:00 Europe/Berlin')

        assert r.relation, :undecidable
        assert r.reason, :dynamic_timezone
      end
    end

    group 'undecidable syntax' do

      test 'is :undecidable for the weekday modulo syntax' do

        r = Fugit::Cron.relate('0 9 * * sun%2', '0 9 * * sun%2', '2026-10-01 00:00:00 UTC')

        assert r.relation, :undecidable
        assert r.reason, :weekday_modulo
      end

      test 'is :undecidable for the random syntax' do

        r = Fugit::Cron.relate('0~30 * * * *', '15 * * * * *', '2026-10-01 00:00:00 UTC')

        assert r.relation, :undecidable
        assert r.reason, :random_syntax
      end

      test 'is :undecidable for the bare random syntax' do

        r = Fugit::Cron.relate('10 ~ * * *', '10 5 * * *', '2026-10-01 00:00:00 UTC')

        assert r.relation, :undecidable
        assert r.reason, :random_syntax
      end
    end

    group 'input forms' do

      test 'accepts Fugit::Cron instances' do

        r = Fugit::Cron.relate(
          Fugit::Cron.parse('0 0 * * 1'),
          Fugit::Cron.parse('0 0 * * 1,2'),
          '2026-10-01 00:00:00 UTC')

        assert r.relation, :subset
      end

      test 'accepts a Time as from' do

        r = Fugit::Cron.relate(
          '0 0 * * 1', '0 0 * * 1,2', Time.utc(2026, 10, 1))

        assert r.relation, :subset
        assert r.witness.to_s, '2026-10-06 00:00:00 Z'
      end

      test 'fails on invalid cron strings' do

        assert_error ArgumentError do
          Fugit::Cron.relate('nada', '0 0 * * *', '2026-10-01 00:00:00 UTC')
        end
      end
    end

    group '#to_h' do

      test 'returns a Hash summary' do

        h = Fugit::Cron.relate('0 0 * * 1', '0 0 * * 1,2').to_h

        assert h[:relation], :subset
        assert h[:reason], nil
        assert h[:witness].class, EtOrbi::EoTime
        assert h[:witness_cron], :b
      end
    end
  end

  group '#relation_to' do

    test 'is the instance counterpart to .relate' do

      r = Fugit::Cron
        .parse('0 0 * * 1')
        .relation_to('0 0 * * 1,2', '2026-10-01 00:00:00 UTC')

      assert r.relation, :subset
      assert r.witness.to_s, '2026-10-06 00:00:00 Z'
    end
  end
end
