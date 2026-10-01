#
# Specifying fugit - structured parse diagnostics
#

group Fugit do

  group '.diagnose_cron' do

    test 'returns a valid (issue-free) report for valid crons' do

      [
        '* * * * *', '0 9 * * 1-5', '*/15 * * * *',
        '0 0 L * *', '0 0 -1 2 *', '@daily', '@yearly',
        '0 0 * * * America/New_York', '0 0 29 2 *', '0 24 * * *',
      ].each { |s| assert Fugit.diagnose_cron(s).valid? }
    end

    test 'agrees with parse_cron on a broad corpus (validity)' do

      tokens = %w[* 0 1 5 23 24 25 59 60 31 32 1 jan feb mon sun 8 L -1
                  */0 */5 5/0 1-5 5-1 mon#2 mon#6 foo @daily @foo]
      srand(42)
      corpus = Array.new(250) { Array.new(rand(3..7)) { tokens.sample }.join(' ') }
      corpus += ['0 25 * * *', '0 0 * *', '0 0 * * * America/Foo',
                 '0 0 31 2 *', '毎 25 * * *', '@daily 0 25 * * *']
      corpus.uniq.each do |s|
        parse_ok = !!(Fugit.parse_cron(s) rescue nil)
        diag = Fugit.diagnose_cron(s)
        expected = parse_ok ? ! diag.hard_invalid? : ! diag.parseable?
        assert(expected, true)
      end
    end

    test 'reports hour out of range for "0 25 * * *" (classic reading)' do

      r = Fugit.diagnose_cron('0 25 * * *')
      i = r.issues.find { |x| x.kind == :out_of_range && x.field == :hours }

      assert i.kind, :out_of_range
      assert i.position, 2
      assert i.length, 2
      assert i.got, 25
      assert i.expected, '0..23'
      assert i.interpretations, [ :ccron ]
      assert '0 25 * * *'[i.position, i.length], '25'
    end

    test 'reports the missing day-of-week under the 6-field reading' do

      r = Fugit.diagnose_cron('0 25 * * *')
      i = r.issues.find { |x| x.kind == :missing_field }

      assert i.field, :weekdays
      assert i.position, 9
      assert i.length, 0
      assert i.interpretations, [ :scron ]
    end

    test 'distinguishes invalid timezone' do

      r = Fugit.diagnose_cron('0 0 * * * America/Foo')
      i = r.issues.find { |x| x.kind == :invalid_timezone }

      assert i.field, :timezone
      assert '0 0 * * * America/Foo'[i.position, i.length], 'America/Foo'
      assert i.got, 'America/Foo'
    end

    test 'reports step zero as out of range and points at the slash' do

      r = Fugit.diagnose_cron('*/0 * * * *')
      i = r.issues.find { |x| x.kind == :out_of_range }

      assert i.field, :minutes
      assert '*/0 * * * *'[i.position, i.length], '/0'
      assert i.got, 0
    end

    test 'reports a day that never exists in the selected month' do

      r = Fugit.diagnose_cron('0 0 31 2 *')
      i = r.issues.find { |x|
        x.kind == :out_of_range && x.field == :monthdays }

      assert i.got, 31
      assert '0 0 31 2 *'[i.position, i.length], '31'
    end

    test 'reports unknown cron aliases' do

      r = Fugit.diagnose_cron('@foobar * * * *')
      i = r.issues.first

      assert i.kind, :unknown_alias
      assert i.position, 0
      assert '@foobar * * * *'[i.position, i.length], '@foobar'
    end

    test 'maps errors after an expanded alias back to the original string' do

      s = '@daily 0 25 * * *'
      r = Fugit.diagnose_cron(s)

      assert r.valid?, false
      r.issues.each { |i| assert(i.position <= s.length, true) }
    end

    test 'accounts for leading whitespace in positions' do

      s = '  0 25 * * *'
      r = Fugit.diagnose_cron(s)
      i = r.issues.find { |x| x.kind == :out_of_range && x.field == :hours }

      assert s[i.position, i.length], '25'
      assert i.position, 4
    end

    test 'uses character (not byte) offsets with multibyte input' do

      s = '毎 25 * * *'
      r = Fugit.diagnose_cron(s)
      i = r.issues.find { |x| x.field == :minutes }

      assert s[i.position, i.length], '毎'
      assert i.position, 0
      assert i.length, 1
    end

    test 'provides a line, column and snippet for UI highlighting' do

      r = Fugit.diagnose_cron('0 25 * * *')
      i = r.issues.find { |x| x.field == :hours }

      assert i.line, 1
      assert i.column, 3
      assert i.snippet.fetch(:segment), '25'
    end
  end

  group '.diagnose_duration' do

    test 'is valid for valid durations (and bare numbers)' do

      [ '1h30', '1Y3M2d', 'P1D', 'PT1H', '5', '', '   ', '-2h' ]
        .each { |s| assert Fugit.diagnose_duration(s).parseable? }
    end

    test 'agrees with parse_duration on a broad corpus' do

      nums = %w[0 1 12 1.5 .5 100 -2 1.2.3]
      units = %w[y M w d h m s Y zz z 分 years min]
      srand(43)
      corpus = Array.new(250) do
        s = Array.new(rand(1..3)) {
          "#{nums.sample}#{['', ' '].sample}#{units.sample}" }.join('')
        body = Array.new(rand(1..3)) {
          "#{rand(0..99)}#{%w[Y M W D H S Z].sample}" }.join
        [ s, "P#{body}" ]
      end.flatten
      corpus.uniq.each do |s|
        parse_ok = !!(Fugit.parse_duration(s) rescue nil)
        diag = Fugit.diagnose_duration(s)
        expected = parse_ok ? ! diag.hard_invalid? : ! diag.parseable?
        assert(expected, true)
      end
    end

    test 'points at the bad unit in "1z" and "1y2z3d"' do

      r = Fugit.diagnose_duration('1z')
      assert '1z'[r.issues.first.position, r.issues.first.length], 'z'

      r = Fugit.diagnose_duration('1y2z3d')
      assert '1y2z3d'[r.issues.first.position, r.issues.first.length], 'z'
    end

    test 'points at a multibyte bad unit using char offsets' do

      r = Fugit.diagnose_duration('1時')
      i = r.issues.first
      assert '1時'[i.position, i.length], '時'
    end

    test 'flags the missing designator in ISO durations' do

      assert Fugit.diagnose_duration('P1').issues.first.kind, :missing_field
    end

    test 'flags a fractional non-second ISO component' do

      i = Fugit.diagnose_duration('P1.5W').issues.first
      assert i.kind, :out_of_range
      assert i.field, :duration
    end
  end

  group '.diagnose_nat' do

    test 'is parseable for valid phrases' do

      [
        'every day at noon', 'every monday at 9', 'at 9:30',
        'every 15 minutes', '', '  ',
      ].each { |s| assert Fugit.diagnose_nat(s).parseable? }
    end

    test 'agrees with parse_nat on a broad corpus' do

      words = %w[every at on noon midnight monday friday day hour hours
                 minutes and or 9 25 9:30 25:00 13:60 in the first 2nd
                 15th of month zzz 毎日]
      srand(44)
      corpus = Array.new(250) { Array.new(rand(1..6)) { words.sample }.join(' ') }
      corpus.uniq.each do |s|
        parse_ok = !!(Fugit.parse_nat(s) rescue nil)
        diag = Fugit.diagnose_nat(s)
        expected = parse_ok ? ! diag.hard_invalid? : ! diag.parseable?
        assert(expected, true)
      end
    end

    test 'flags out-of-range digital clock values' do

      i = Fugit.diagnose_nat('at 25:00').issues.first
      assert i.kind, :out_of_range
      assert 'at 25:00'[i.position, i.length], '25'

      i = Fugit.diagnose_nat('at 13:60').issues.first
      assert 'at 13:60'[i.position, i.length], '60'
    end

    test 'flags an invalid timezone' do

      i = Fugit.diagnose_nat(
        'every day at noon in America/Foo').issues.first
      assert i.kind, :invalid_timezone
      assert i.field, :timezone
      assert(
        'every day at noon in America/Foo'[i.position, i.length],
        'America/Foo')
    end

    test 'flags multiple distinct cron interpretations as ambiguous' do

      r = Fugit.diagnose_nat('at 9:00 and 10:30')

      assert r.ambiguous?
      assert r.parseable? # legacy parse still accepts it (first cron)
      assert r.interpretations.size, 2
    end

    test 'points at unrecognized text using char offsets' do

      s = '毎日 at noon'
      i = Fugit.diagnose_nat(s).issues.first
      assert s[i.position, i.length], '毎日'
    end
  end

  group '.diagnose' do

    test 'does not change the legacy parse return contract' do

      assert(Fugit.parse_cron('0 25 * * *'), nil)
      assert(Fugit.parse_duration('1z'), nil)
      assert(Fugit.parse_nat('zzz'), nil)

      assert Fugit.parse('0 9 * * mon').class, Fugit::Cron

      e = (Fugit.do_parse_cron('0 25 * * *') rescue $!)
      assert e.class, ArgumentError
    end

    test 'collects structured issues from every entry point' do

      r = Fugit.diagnose('0 25 * * *')

      assert r.class, Fugit::Diagnose::Report
      assert r.valid?, false
      assert r.issues.map(&:format).include?(:cron)
      assert r.issues.all? { |i| i.position.is_a?(Integer) }
    end

    test 'is valid when one entry point parses the input' do

      assert Fugit.diagnose('every day at noon').valid?
      assert Fugit.diagnose('0 9 * * mon').valid?
      assert Fugit.diagnose('1h30m').parseable?
    end

    test 'serializes to a hash with stable keys' do

      h = Fugit.diagnose_cron('0 25 * * *').to_h

      assert h[:valid], false
      assert h[:issues].class, Array
      assert h[:issues].first.key?(:kind)
      assert h[:issues].first.key?(:position)
      assert h[:issues].first.key?(:length)
      assert h[:issues].first.key?(:expected)
    end
  end
end
