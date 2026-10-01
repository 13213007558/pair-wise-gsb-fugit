#
# Specifying fugit
#
# The "H" (stable hash) extension, see README "the hash extension"
#

group Fugit::Cron do

  K = 'tenant-001'

  # Fixed vectors. The hash is MD5 based and must not depend on the
  # Ruby version, the process, String#hash seeds, or parse order.
  #
  VECTORS = {

    # 5 fields: min hou dom mon dow

    [ 'H * * * *',           K ]          => [ '37 * * * *', :minutes, [ 37 ] ],
    [ 'H(0-29) * * * *',     K ]          => [ '7 * * * *', :minutes, [ 7 ] ],
    [ 'H(0-9)/2 * * * *',    K ]          =>
      [ '1,3,5,7,9 * * * *', :minutes, [ 1, 3, 5, 7, 9 ] ],
    [ 'H/30 * * * *',        K ]          =>
      [ '7,37 * * * *', :minutes, [ 7, 37 ] ],
    [ 'H/60 * * * *',        K ]          => [ '37 * * * *', :minutes, [ 37 ] ],
    [ 'H/61 * * * *',        K ]          => [ '37 * * * *', :minutes, [ 37 ] ],
    [ 'H(30-30) * * * *',    K ]          => [ '30 * * * *', :minutes, [ 30 ] ],
    [ 'H,H * * * *',         K ]          =>
      [ '24,37 * * * *', :minutes, [ 24, 37 ] ],
    [ 'h * * * *',           K ]          => [ '37 * * * *', :minutes, [ 37 ] ],

    [ '0 H * * *',           K ]          => [ '0 17 * * *', :hours, [ 17 ] ],
    [ '0 H(20-23) * * *',    K ]          => [ '0 21 * * *', :hours, [ 21 ] ],
    [ '0 H(9-17)/4 * * *',   K ]          =>
      [ '0 10,14 * * *', :hours, [ 10, 14 ] ],

    [ '0 0 H(1-31) * *',     K ]          => [ '0 0 7 * *', :monthdays, [ 7 ] ],
    [ '0 0 0 * H(1-12) *',   K ]          => [ '0 0 * 5 *', :months, [ 5 ] ],

    [ '0 0 * * H',           K, 'ns' ]    =>
      [ '0 0 * * 0', :weekdays, [ [ 0 ] ] ],
    [ '0 0 * * H(1-5)',      K ]          =>
      [ '0 0 * * 3', :weekdays, [ [ 3 ] ] ],
    [ '0 0 * * H(0-6)',      K ]          =>
      [ '0 0 * * 2', :weekdays, [ [ 2 ] ] ],

    # 6 fields: sec min hou dom mon dow

    [ '0 H/15 H(8-20) * * 1-5', K ]       =>
      [ '7,22,37,52 10 * * 1,2,3,4,5', :minutes, [ 7, 22, 37, 52 ] ],
  }

  VECTORS.each do |(s, key, ns), (cron_s, field, values)|

    test "expands #{s.inspect} (fixed vector)" do

      c = Fugit.do_parse_cron(s, key: key, namespace: ns)

      assert c.class, Fugit::Cron
      assert c.original, s
      assert c.expanded, cron_s
      assert c.to_cron_s, cron_s
      assert c.send(field), values
    end
  end

  test 'H/step covers the full field with a stable phase' do

    c = Fugit.do_parse_cron('H/10 * * * *', key: K)

    assert c.minutes, [ 7, 17, 27, 37, 47, 57 ]
  end

  test 'an out of range bounded phase yields an empty (never) field' do

    # H(0-0)/5: the grid inside [0,0] only accepts phase 0; key "x"
    # happens to land on another phase, so the field is empty

    c = Fugit.parse_cron('H(0-0)/5 * * * *', key: 'x')

    assert c.class, Fugit::Cron
    assert c.minutes, []
  end

  test 'returns nil for out of range or malformed H bounds' do

    assert_nil Fugit.parse_cron('H(0-60) * * * *', key: K) # minute max 59
    assert_nil Fugit.parse_cron('0 H(0-24) * * *', key: K) # hour max 23
    assert_nil Fugit.parse_cron('H(7-6) * * * *', key: K)  # reversed
    assert_nil Fugit.parse_cron('H/0 * * * *', key: K)     # step < 1
    assert_nil Fugit.parse_cron('0 0 * * H(0-7)', key: K)  # weekday max 6
    assert_nil Fugit.parse_cron('0 0 0 H(32-32) * *', key: K) # dom max 31
  end

  test 'fails (ArgumentError) when no key is provided' do

    assert_error(
      lambda { Fugit.do_parse_cron('0 H * * *') },
      ArgumentError)
    assert_error(
      lambda { Fugit.parse_cron('0 H * * *') },
      ArgumentError)
  end

  test 'plain crons do not require a key and are not marked hashed' do

    c = Fugit.do_parse_cron('0 12 * * *')

    assert c.hash_fields, []
    assert_nil c.hash_key
  end

  test 'records which fields are hashed and the key/namespace' do

    c = Fugit.do_parse_cron('0 H/15 H(8-20) * * 1-5', key: K, namespace: 'j')

    assert c.hash_fields, %w[ minutes hours ]
    assert c.hash_key, K
    assert c.hash_namespace, 'j'
  end

  test 'is stable across parses' do

    c1 = Fugit.do_parse_cron('H/30 H(9-17) * * *', key: K, namespace: 'ns')
    c2 = Fugit.do_parse_cron('H/30 H(9-17) * * *', key: K, namespace: 'ns')

    assert c1.expanded, c2.expanded
    assert c1.to_a, c2.to_a
  end

  test 'does not rely on the process-seeded String#hash' do

    # The expansion goes through Digest::MD5, not Kernel#hash, so
    # whatever the (seeded) String#hash is, the result is fixed.

    s = 'H * * * *'

    def s.hash; 0; end # neutralize, just to prove Kernel#hash is unused

    c = Fugit.do_parse_cron(s, key: K)

    assert c.minutes, [ 37 ]
  end

  test 'hash fields are independent of one another' do

    c1 = Fugit.do_parse_cron('H 0 * * *', key: K)
    c2 = Fugit.do_parse_cron('H 23 * * *', key: K)
    c3 = Fugit.do_parse_cron('H 0 * * 1-5', key: K)

    assert c1.minutes, c2.minutes
    assert c2.minutes, c3.minutes
  end

  test 'a field is salted by its position, not the parse order' do

    # position 0 of the minute field hashes the same alone or in a list

    alone = Fugit.do_parse_cron('H * * * *', key: K).minutes
    listed = Fugit.do_parse_cron('H,H * * * *', key: K).minutes

    assert listed.include?(alone.first), true
    assert listed.length, 2 # position 1 is salted independently

    # the hour field carries a different salt than the minute field

    h = Fugit.do_parse_cron('0 H * * *', key: K).hours

    assert h.first != alone.first, true
  end
  test 'multiple H placeholders in a field are independently salted' do

    c = Fugit.do_parse_cron('H,H * * * *', key: K)

    assert c.minutes.length, 2
    assert c.minutes.uniq.length, 2
  end

  test 'the key affects only hashed fields' do

    c1 = Fugit.do_parse_cron('17 H * * 1-5', key: 'k1')
    c2 = Fugit.do_parse_cron('17 H * * 1-5', key: 'k2-something-else')

    assert c1.minutes, [ 17 ] # literal, untouched
    assert c2.minutes, [ 17 ] # literal, untouched

    assert c1.weekdays, c2.weekdays # not hashed, untouched
    assert(c1.hours != c2.hours) # hashed, re-decided
  end

  test 'the namespace participates in the hash' do

    c1 = Fugit.do_parse_cron('H * * * *', key: K, namespace: 'a')
    c2 = Fugit.do_parse_cron('H * * * *', key: K, namespace: 'b')

    assert(c1.expanded != c2.expanded)
  end

  test 'distributes keys across the whole range' do

    minutes =
      (1..1500).collect { |i|
        Fugit.do_parse_cron('H * * * *', key: "t#{i}").minutes.first }

    assert minutes.uniq.sort, (0..59).to_a

    phases =
      (1..1500).collect { |i|
        Fugit.do_parse_cron('H/10 * * * *', key: "t#{i}").minutes.first }

    assert phases.uniq.sort, (0..9).to_a
  end

  test 'H(0-23) and H agree in the hour field' do

    c1 = Fugit.do_parse_cron('0 H * * *', key: K)
    c2 = Fugit.do_parse_cron('0 H(0-23) * * *', key: K)

    assert c2.hours, c1.hours
  end
  test 'survives Marshal and reproduces the same trigger sequence' do

    c = Fugit.do_parse_cron('H/15 H(8-20) * * 1-5', key: K, namespace: 'jobs')

    d = Marshal.load(Marshal.dump(c))

    assert d.original, c.original
    assert d.expanded, c.expanded
    assert d.hash_key, c.hash_key
    assert d.hash_namespace, c.hash_namespace

    from = Time.utc(2026, 1, 1)

    assert d.next(from).take(8).collect(&:to_i),
           c.next(from).take(8).collect(&:to_i)
  end

  test 'the expanded expression drives matching' do

    c = Fugit.do_parse_cron('H * * * *', key: K) # minute 37

    assert c.match?(Time.utc(2026, 1, 1, 12, 37)), true
    assert c.match?(Time.utc(2026, 1, 1, 12, 38)), false
  end

  test 'the random tilde behaviour is untouched' do

    c = Fugit.parse('~ * * * *', random: false)

    assert c.class, Fugit::Cron
    assert c.expanded, '0 * * * *'
    assert c.hash_fields, []
  end

  test 'mixes with literal elements in a list' do

    c = Fugit.do_parse_cron('H,30 * * * *', key: K)

    assert c.minutes.include?(30), true
    assert c.minutes.length, 2

    d = Fugit.do_parse_cron('0 0 * * mon,H', key: K)

    assert d.weekdays.include?([ 1 ]), true
    assert d.weekdays.length, 2
  end

  test 'accepts weekday and month names as H bounds' do

    c = Fugit.do_parse_cron('0 0 * * H(mon-fri)', key: K)

    assert c.weekdays.length, 1
    assert (1..5).include?(c.weekdays.first.first), true
  end

  test 'coexists with a timezone following an H weekday' do

    c = Fugit.do_parse_cron('0 0 * * H America/New_York', key: K)

    assert c.class, Fugit::Cron
    assert c.zone, 'America/New_York'
    assert c.weekdays.length, 1
  end

  test 'works in the seconds field' do

    c = Fugit.do_parse_cron('H 0 0 * * *', key: 'x')

    assert c.seconds.length, 1
    assert(c.seconds.first >= 0 && c.seconds.first <= 59)
  end

  test 'the weekday hash (#) extension is untouched' do

    c = Fugit.do_parse_cron('0 0 * * mon#2')

    assert c.expanded, '0 0 * * 1#2'
    assert c.weekdays, [ [ 1, 2 ] ]
  end

  test 'accepts hash_key/hash_namespace aliases' do

    c = Fugit.do_parse_cron(
      'H * * * *', hash_key: K, hash_namespace: 'ns')

    assert c.minutes, [ 27 ]
    assert c.hash_namespace, 'ns'
  end
end
