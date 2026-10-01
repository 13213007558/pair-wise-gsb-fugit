#
# Specifying fugit
#
# Diagnostic parsing entry points (Fugit.diagnose, #diagnose_cron,
# #diagnose_duration, #diagnose_nat).
#

group Fugit do

  group '.diagnose_cron' do

    test 'returns nil for a valid cron' do

      assert_nil Fugit.diagnose_cron('0 0 * * *')
      assert_nil Fugit.diagnose_cron('30 0 9 * * 1-5')
    end

    test 'flags an out of range hour at its exact position' do

      d = Fugit.diagnose_cron('0 25 * * *')

      assert d.code, :out_of_range
      assert d.fields, [ :hours ]
      assert d.pos, 2
      assert d.len, 2
      assert d.slice, '25'
      assert d.details, 'expected 0..23, got 25'
    end

    test 'counts leading whitespace in positions' do

      d = Fugit.diagnose_cron('  0 25 * * *  ')

      assert d.code, :out_of_range
      assert d.pos, 4
      assert d.len, 2
      assert d.slice, '25'
      assert d.end_pos, 6
    end

    test 'reports a missing field with a zero-length span at the end' do

      d = Fugit.diagnose_cron('0 0 * *')

      assert d.code, :missing_field
      assert d.fields, [ :weekdays ]
      assert d.pos, 7
      assert d.len, 0
    end

    test 'distinguishes an invalid timezone' do

      d = Fugit.diagnose_cron('0 0 * * * America/Foo')

      assert d.code, :invalid_timezone
      assert d.fields, [ :timezone ]
      assert d.slice, 'America/Foo'
      assert d.pos, 10
    end

    test 'flags an explicit zero step' do

      d = Fugit.diagnose_cron('*/0 * * * *')

      assert d.code, :invalid_step
      assert d.fields, [ :minutes ]
      assert d.slice, '*/0'
    end

    test 'flags mixed negative/positive range bounds' do

      d = Fugit.diagnose_cron('0 0 -5-3 * *')

      assert d.code, :mixed_signs
      assert d.fields, [ :monthdays ]
      assert d.slice, '-5-3'
    end

    test 'flags an out of range weekday occurrence (#n)' do

      d = Fugit.diagnose_cron('0 0 * * 6#6')

      assert d.code, :out_of_range
      assert d.fields, [ :weekdays ]
      assert d.slice, '#6'
    end

    test 'flags a schedule that can never occur (Feb 31)' do

      d = Fugit.diagnose_cron('* * 31 2 *')

      assert d.code, :never_occurs
      assert d.fields, [ :monthdays, :months ]
      assert d.slice, '31 2'
    end

    test 'does not flag Feb 29' do

      assert_nil Fugit.diagnose_cron('0 0 29 2 *')
    end

    test 'reports unknown aliases on the alias token' do

      d = Fugit.diagnose_cron('@bogus')

      assert d.code, :unknown_alias
      assert d.slice, '@bogus'
    end

    test 'explains @reboot cannot be expanded' do

      d = Fugit.diagnose_cron('@reboot')

      assert d.code, :unsupported_alias
      assert d.slice, '@reboot'
    end

    test 'maps errors after a shorthand alias back onto the alias/trailer' do

      d = Fugit.diagnose_cron('@daily 99')

      assert d.code, :unexpected_token
      assert d.slice, '99'
      assert d.pos, 7
    end

    test 'flags 6-field seconds vs classic+extra ambiguity' do

      d = Fugit.diagnose_cron('61 0 * * * *')

      assert d.code, :ambiguous
      assert d.candidates.size, 2
      assert d.candidates.first.code, :out_of_range
    end

    test 'resolves 5-field classic as non ambiguous' do

      d = Fugit.diagnose_cron('0 25 * * *')

      assert d.code, :out_of_range
      assert_nil d.candidates
    end

    test 'handles non ASCII (ideographic) leading whitespace' do

      d = Fugit.diagnose_cron("\u{3000}0 0 * * *")

      assert d.code, :invalid_value
      assert d.pos, 0
    end

    test 'exposes byte offsets consistent with the character slice' do

      s = '0 25あ * * *'
      d = Fugit.diagnose_cron(s)

      assert d.slice, 'あ'
      assert d.pos, 4
      assert d.len, 1
      assert d.byte_pos, 4
      assert d.byte_len, 3
      assert s.byteslice(d.byte_pos, d.byte_len).bytes, 'あ'.bytes
    end

    test 'byte offsets work with a multibyte leftover after a star' do

      s = '0 0 31 2 *中'
      d = Fugit.diagnose_cron(s)

      assert s.byteslice(d.byte_pos, d.byte_len).bytes, d.slice.bytes
    end

    test 'returns a structured hash' do

      h = Fugit.diagnose_cron('0 25 * * *').to_h

      assert h[:type], :cron
      assert h[:code], :out_of_range
      assert h[:fields], [ :hours ]
      assert h[:expected].first, 'integer 0-23 or "*"'
      assert h.key?(:byte_pos), true
    end
  end

  group '.diagnose_duration' do

    test 'returns nil for a valid duration' do

      assert_nil Fugit.diagnose_duration('1h30m')
      assert_nil Fugit.diagnose_duration('PT1H30M')
    end

    test 'flags an unknown plain unit on the unit char' do

      d = Fugit.diagnose_duration('12x')

      assert d.code, :invalid_unit
      assert d.slice, 'x'
      assert d.pos, 2
    end

    test 'flags an unknown unit later in the sequence' do

      d = Fugit.diagnose_duration('1h 30x')

      assert d.code, :invalid_unit
      assert d.slice, 'x'
      assert d.pos, 5
    end

    test 'flags an invalid ISO designator' do

      d = Fugit.diagnose_duration('P1X')

      assert d.code, :invalid_unit
      assert d.slice, 'X'
    end

    test 'flags a missing ISO value or designator' do

      d = Fugit.diagnose_duration('PT')

      assert d.code, :missing_field
      assert d.pos, 2
    end

    test 'flags a number without an ISO designator' do

      d = Fugit.diagnose_duration('P1H30')

      assert d.code, :missing_field
      assert d.slice, '30'
    end
  end

  group '.diagnose_nat' do

    test 'returns nil for valid natural language' do

      assert_nil Fugit.diagnose_nat('every day at noon')
    end

    test 'points at the first unrecognized word' do

      d = Fugit.diagnose_nat('evry day')

      assert d.code, :not_natural_language
      assert d.slice, 'evry'
      assert d.pos, 0
    end

    test 'distinguishes an invalid timezone in a phrase' do

      d = Fugit.diagnose_nat('every day at noon America/Foo')

      assert d.code, :invalid_timezone
      assert d.fields, [ :timezone ]
      assert d.slice, 'America/Foo'
      assert d.pos, 18
    end

    test 'points at an out of range clock time' do

      d = Fugit.diagnose_nat('every day at 25:00')

      assert d.code, :not_natural_language
      assert d.slice, '25:00'
    end

    test 'accounts for leading whitespace and multibyte trailers' do

      s = "  every day at 25:00 \u{4e2d}"
      d = Fugit.diagnose_nat(s)

      assert d.code, :not_natural_language
      assert d.slice, '25:00'
      assert s.byteslice(d.byte_pos, d.byte_len).bytes, d.slice.bytes
    end
  end

  group '.diagnose' do

    test 'returns nil if any entry parses' do

      assert_nil Fugit.diagnose('0 0 * * *')
      assert_nil Fugit.diagnose('1h30m')
      assert_nil Fugit.diagnose('every monday at noon')
    end

    test 'picks the cron diagnosis for a cron-shaped bad month token' do

      d = Fugit.diagnose('0 0 * * 2025')

      assert d.type, :cron
      assert d.code, :out_of_range
      assert d.slice, '2025'
    end

    test 'stays consistent with Fugit.parse (at entry overlap)' do

      # "0 25 * * *" is read by et-orbi as a time, so Fugit.parse succeeds
      assert_not_nil Fugit.parse('0 25 * * *')
      assert_nil Fugit.diagnose('0 25 * * *')

      # the cron-specific entry still diagnoses it independently
      assert Fugit.diagnose_cron('0 25 * * *').code, :out_of_range
    end

    test 'picks the duration diagnosis for a number with a bad unit' do

      # the duration-specific entry flags it directly
      d = Fugit.diagnose_duration('1h 30x')

      assert d.type, :duration
      assert d.code, :invalid_unit
      assert d.slice, 'x'
    end

    test 'generic diagnose returns the closest entry for junk input' do

      d = Fugit.diagnose('completely unparseable gibberish !!!')

      assert_not_nil d
      assert d.code != nil, true
    end

    test 'still honors the old parse contract (nil on failure)' do

      assert_nil Fugit.parse_cron('0 25 * * *')
      assert_nil Fugit.parse_duration('12x')
    end

    test 'does not change do_parse error behavior' do

      assert_error(ArgumentError) { Fugit.do_parse_cron('0 25 * * *') }
    end
  end
end
