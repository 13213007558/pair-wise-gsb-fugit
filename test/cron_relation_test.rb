#
# Specifying fugit
# Cron schedule relation analysis
#

group Fugit::CronRelation do

  group 'the five relations' do

    test 'equal schedules' do

      r = Fugit.cron_relation('0 0 * * *', '0 0 * * *')

      assert(r.relation, :equal)
      assert(r.witness, nil)
      assert_true(r.equal?)
    end

    test 'directed containment (a contains b)' do

      r = Fugit.cron_relation('0 0 1,15 * 5', '0 0 * * 5')

      assert(r.relation, :contains)
      assert(r.side, :a)
      assert_true(r.contains?)
    end

    test 'directed containment (a contained by b)' do

      r = Fugit.cron_relation('0 0 * * 5', '0 0 1,15 * 5')

      assert(r.relation, :contained)
      assert(r.side, :b)
      assert_true(r.contained?)
    end

    test 'intersection' do

      # last day of February is the 29th in leap years, 28th otherwise
      #
      r = Fugit.cron_relation('0 0 L 2 *', '0 0 28 2 *')

      assert(r.relation, :intersects)
      assert_true(r.intersects?)
    end

    test 'disjoint schedules' do

      r = Fugit.cron_relation('0 0 29 2 *', '0 0 28 2 *')

      assert(r.relation, :disjoint)
      assert_true(r.disjoint?)
    end

    test 'disjoint time slots on identical days' do

      r = Fugit.cron_relation('0 0 * * *', '30 0 * * *')

      assert(r.relation, :disjoint)
    end

    test 'intersecting time slots on identical days' do

      r = Fugit.cron_relation('0,30 0 * * *', '30,45 0 * * *')

      assert(r.relation, :intersects)
    end

    test 'containment driven by time slots' do

      r = Fugit.cron_relation('0 0 * * mon', '0,30 0 * * mon,tue')

      assert(r.relation, :contained)
      assert(r.side, :b)
    end
  end

  group 'the witness' do

    test 'is the earliest distinguishing instant from the given start' do

      r = Fugit.cron_relation('0 0 29 2 *', '0 0 28 2 *', '2023-06-01 UTC')

      assert(r.relation, :disjoint)
      assert(r.witness.strftime('%F %T'), '2024-02-28 00:00:00')
      assert(r.side, :b)
    end

    test 'ignores slots of the from day that precede the start' do

      # at 06:00, that day's 00:00 (only b fires) is in the past
      #
      r = Fugit.cron_relation('0 0,12 * * *', '0 0 * * *', '2024-03-01 06:00:00 UTC')

      assert(r.relation, :contains)
      assert(r.witness.strftime('%F %T'), '2024-03-01 12:00:00')
      assert(r.side, :a)
    end

    test 'can coincide exactly with the start' do

      r = Fugit.cron_relation('0 0,12 * * *', '0 0 * * *', '2024-03-01 12:00:00 UTC')

      assert(r.witness.strftime('%F %T'), '2024-03-01 12:00:00')
    end

    test 'falls in the witness schedule zone for fixed-offset zones' do

      r = Fugit.cron_relation(
        '0 0 * * * +08:00',
        '30 0 * * * +08:00',
        '2024-03-01 UTC')

      assert(r.relation, :disjoint)
      assert(r.witness.strftime('%F %T %:z'), '2024-03-02 00:00:00 +08:00')
    end

    test 'is found past a start long before the next divergence' do

      # the first February 29th after 1999 is 2000-02-29
      #
      r = Fugit.cron_relation('0 0 29 2 *', '0 0 L 2 *', '1999-01-01 UTC')

      assert(r.relation, :contained)
      assert(r.witness.strftime('%F'), '1999-02-28')
    end
  end

  group 'supported notations' do

    test 'month names and month lists' do

      r = Fugit.cron_relation('0 0 * jan,jul *', '0 0 * * *')

      assert(r.relation, :contained)
    end

    test 'last day (L / -1)' do

      r = Fugit.cron_relation('0 0 L * *', '0 0 -1 * *', '2024-03-01 UTC')

      assert(r.relation, :equal)
    end

    test 'negative month days' do

      r = Fugit.cron_relation('0 0 -1,-2 * *', '0 0 L * *')

      assert(r.relation, :contains)
      assert(r.side, :a)
    end

    test 'nth weekday of month' do

      r = Fugit.cron_relation('0 0 * * mon#1', '0 0 * * mon#2')

      assert(r.relation, :disjoint)
    end

    test 'last nth weekday of month' do

      # "L * mon" is OR semantics (last day OR any Monday), so the exact
      # last-Monday rule is a strict subset
      #
      r = Fugit.cron_relation('0 0 * * mon#-1', '0 0 L * mon', '2024-03-01 UTC')

      assert(r.relation, :contained)
      assert(r.side, :b)
    end

    test 'dom and dow OR semantics' do

      r = Fugit.cron_relation('0 0 1,15 * 5', '0 0 * * mon-fri')

      assert(r.relation, :intersects)
    end

    test 'dom and dow AND extension (&)' do

      # the 1st that is also a Friday, subset of the 1st
      #
      r = Fugit.cron_relation('0 0 1 * 5&', '0 0 1 * *')

      assert(r.relation, :contained)
    end

    test 'seconds field' do

      r = Fugit.cron_relation('15 0 * * * *', '0,15 0 * * * *')

      assert(r.relation, :contained)
      assert(r.side, :b)
    end

    test 'UTC explicit zone' do

      r = Fugit.cron_relation('0 0 * * * UTC', '0 0 * * *')

      assert(r.relation, :equal)
    end
  end

  group 'undecidable inputs' do

    test 'dynamic timezone (DST)' do

      r = Fugit.cron_relation('0 0 * * * America/New_York', '0 0 * * *')

      assert(r.relation, :undecidable)
      assert_not_nil(r.reason)
    end

    test 'two different fixed offsets' do

      r = Fugit.cron_relation('0 0 * * * +08:00', '0 0 * * * +05:30')

      assert(r.relation, :undecidable)
    end

    test 'weekday modulo notation' do

      r = Fugit.cron_relation('0 0 * * mon%2', '0 0 * * mon')

      assert(r.relation, :undecidable)
    end

    test 'random notation' do

      r = Fugit.cron_relation('0 0 1~5 * *', '0 0 1 * *')

      assert(r.relation, :undecidable)
    end
  end

  group 'API' do

    test 'Fugit.cron_relation and Cron#relation_to agree' do

      c = Fugit.parse_cron('0 0 * * *')

      r0 = Fugit.cron_relation(c, '0 0 * * mon')
      r1 = c.relation_to('0 0 * * mon')

      assert(r0.relation, r1.relation)
      assert(r1.relation, :contains)
    end

    test 'accepts Fugit::Cron instances' do

      a = Fugit.do_parse_cron('0 0 * * *')
      b = Fugit.do_parse_cron('0 0 * * *')

      assert(Fugit::CronRelation.new(a, b).analyze(Time.utc(2024, 1, 1)).relation,
             :equal)
    end
  end

  # A short window ("try the next year") cannot separate these two rules:
  # they agree on every common year. They only differ in leap years, where
  # February has 29 days, exactly the case the 400-year symbolic cycle
  # captures. Starting in 2001, the earliest witness is 2004-02-29.
  #
  group 'leap-year only divergence (no short window guess)' do

    test 'Feb 29 vs last-of-Feb differ solely on leap years' do

      r = Fugit.cron_relation('0 0 29 2 *', '0 0 L 2 *', '2001-01-01 UTC')

      assert(r.relation, :contained)
      assert(r.side, :b)
      assert(r.witness.strftime('%F'), '2001-02-28')

      # at the shared leap instant itself, nothing distinguishes them;
      # the next divergence is another common-year February 28th
      #
      r2 = Fugit.cron_relation('0 0 29 2 *', '0 0 L 2 *', '2004-02-29 UTC')

      assert(r2.relation, :contained)
      assert(r2.witness.strftime('%F'), '2005-02-28')
    end

    test 'Feb 29 vs Feb 28 are disjoint, first witness after 2001 leap' do

      r = Fugit.cron_relation('0 0 29 2 *', '0 0 28 2 *', '2001-03-01 UTC')

      assert(r.relation, :disjoint)
      assert(r.witness.strftime('%F'), '2002-02-28')
    end

    test 'the century-leap rule is exercised (2100 is not a leap year)' do

      # after 2096, the next Feb 29 is 2104; 2100 is common
      #
      r = Fugit.cron_relation('0 0 29 2 *', '0 0 28 2 *', '2096-03-01 UTC')

      assert(r.relation, :disjoint)
      assert(r.witness.strftime('%F'), '2097-02-28')

      # whereas 2000, a century year divisible by 400, is leap
      #
      r2 = Fugit.cron_relation('0 0 29 2 *', '0 0 28 2 *', '2000-01-01 UTC')

      assert(r2.witness.strftime('%F'), '2000-02-28')
    end
  end
end
