# frozen_string_literal: true

module Fugit

  # A structured, non-destructive companion to the various `Fugit.parse*`
  # methods.
  #
  # While `Fugit.parse_cron`, `Fugit.parse_duration`, and `Fugit.parse_nat`
  # return `nil` on failure (and their `do_parse_*` counterparts raise a
  # generic ArgumentError), `Fugit.diagnose_*` never changes that contract
  # and instead returns a Fugit::Diagnostic instance that points at where
  # the input went wrong, which field is involved, and what was expected.
  #
  # Positions are reported both as character offsets (`:pos`, `:len`) and
  # as byte offsets (`:byte_pos`, `:byte_len`) so that user interfaces can
  # highlight the offending slice of the *original* string, leading
  # whitespace and multibyte characters included. Aliases (`@daily` and
  # friends) and shorthands are re-mapped back onto the original text.
  #
  class Diagnostic

    attr_reader \
      :type, :code, :fields, :message,
      :pos, :len, :end_pos,
      :expected, :details,
      :alternatives, :candidates,
      :original, :syntax

    def initialize(type, code, opts={})

      @type = type
      @code = code
      @fields = Array(opts[:fields]).flatten.compact.uniq
      @message = opts[:message]
      @expected =
        opts.key?(:expected) ? (opts[:expected].is_a?(Array) ?
          opts[:expected] : [ opts[:expected] ]) :
        nil
      @details = opts[:details]
      @alternatives = opts[:alternatives]
      @candidates = opts[:candidates]
      @syntax = opts[:syntax]

      @original = opts[:original]

      @pos = opts[:pos]
      @len = opts[:len]
      @len = (@original && @pos) ?
        (@original.length - @pos) : 0 if @len == nil
      @end_pos = (@pos || 0) + (@len || 0)

      @byte_pos, @byte_len = compute_byte_positions
    end

    # The slice of the original string covered by this diagnostic.
    #
    def slice; (@pos && @original) ? @original[@pos, @len] : nil; end

    def byte_pos; @byte_pos; end
    def byte_len; @byte_len; end
    def byte_end_pos; @byte_pos + @byte_len; end

    # One-based line and zero-based column (character) of #pos.
    #
    def line_and_column

      return nil unless @pos && @original

      pre = @original[0, @pos]
      line = pre.count("\n") + 1
      col = @pos - (pre.rindex("\n") || -1) - 1

      [ line, col ]
    end

    # A ready to render "line\n  ^---" view of the failure location.
    #
    def visual

      return nil unless @pos && @original

      line, col = line_and_column
      src = @original.split("\n", -1)[line - 1]

      "#{src}\n#{' ' * col}^---"
    end

    def ambiguous?; @code == :ambiguous; end
    def missing?; @code == :missing_field; end
    def out_of_range?; @code == :out_of_range; end
    def invalid_timezone?; @code == :invalid_timezone; end

    def to_h

      h = {
        type: @type, code: @code, fields: @fields, message: @message,
        pos: @pos, len: @len, end_pos: @end_pos,
        byte_pos: @byte_pos, byte_len: @byte_len,
        byte_end_pos: byte_end_pos }
      h[:expected] = @expected if @expected
      h[:details] = @details if @details
      h[:syntax] = @syntax if @syntax
      h[:alternatives] = @alternatives.map(&:to_h) if @alternatives
      h[:candidates] = @candidates.map(&:to_h) if @candidates
      h
    end
    alias to_hash to_h

    def inspect

      a = [ @type.inspect, @code.inspect ]
      a << @fields.inspect if @fields.any?
      a << "#{@pos}..#{@end_pos}" if @pos
      "(diagnostic #{a.join(' ')})"
    end

    protected

    def compute_byte_positions

      return [ nil, nil ] unless @pos && @original

      prefix = @original[0, @pos]
      target = @original[@pos, @len].to_s

      [ prefix.bytesize, target.bytesize ]
    end
  end

  module DiagnosticHelpers

    protected

    # ASCII-only strip, matching the String#strip used by the parsers
    # (U+3000 and other non-ASCII whitespace is not stripped there).
    #
    def ascii_strip(s)

      s.sub(/\A[ \t\r\n\f\v]+/, '').sub(/[ \t\r\n\f\v]+\z/, '')
    end

    def lead(s0, s)

      i = s0.index(s)
      i || 0
    end

    def too_long(type, s0, len)

      Fugit::Diagnostic.new(
        type, :too_long,
        original: s0, pos: 0,
        message:
          "input too long, #{len} characters over the " +
          "#{::Fugit::MAX_INPUT_LENGTH} character limit",
        expected:
          "no more than #{::Fugit::MAX_INPUT_LENGTH} characters",
        details: { length: len, max: ::Fugit::MAX_INPUT_LENGTH })
    end
  end

  module CronDiagnostic
    include DiagnosticHelpers

    extend self

    # min/max for the bare numeric bounds of each cron field.
    #
    BOUNDS = {
      seconds: [ 0, 59 ],
      minutes: [ 0, 59 ],
      hours: [ 0, 23 ],
      monthdays: [ 1, 31 ],
      months: [ 1, 12 ],
      weekdays: [ 0, 7 ],
    }.freeze

    CLASSIC = %i[ minutes hours monthdays months weekdays ].freeze
    SECONDS = %i[ seconds minutes hours monthdays months weekdays ].freeze

    WRAPPERS = {
      seconds: :lsec_, minutes: :lmin_, hours: :lhou_,
      monthdays: :ldom_, months: :lmon_, weekdays: :ldow,
    }.freeze

    EXPECTED = {
      seconds: 'integer 0-59 or "*"',
      minutes: 'integer 0-59 or "*"',
      hours: 'integer 0-23 or "*"',
      monthdays: 'integer 1-31, "L"/"last", or "*"',
      months: 'integer 1-12, month name (jan..dec), or "*"',
      weekdays: 'integer 0-7, weekday name (sun..sat), or "*"',
    }.freeze

    FIELD_LABELS = {
      seconds: 'seconds', minutes: 'minutes', hours: 'hours',
      monthdays: 'day of month', months: 'month', weekdays: 'day of week',
      timezone: 'timezone',
    }.freeze

    # Mirrors the cron parser's _tz_delta and _tz_name rules.
    #
    TZ_LIKE =
      %r{\A(?:
         [A-Z][a-zA-Z0-9+\-]+(?:/[A-Z][a-zA-Z0-9+\-_]+){0,2} # Area/Location
         | UTC | Z                                          # aliases
         | [-+](?:[01][0-9]|2[0-4]):?(?:00|15|30|45)        # HH:MM delta
         )\z}x.freeze

    SPECIAL_ALIASES = Fugit::Cron::SPECIALS.keys.freeze

    def diagnose(s0, opts={})

      return nil unless s0.is_a?(String)

      s = ascii_strip(s0)

      if s.length > ::Fugit::MAX_INPUT_LENGTH
        return too_long(:cron, s0, s.length)
      end

      leading = lead(s0, s)
      alias_map = nil

      if s[0, 1] == '@'

        name = s.split(/[ \t]/, 2)[0]

        unless Fugit::Cron::SPECIALS.has_key?(name)
          return make(
            :unknown_alias, :timezone,
            pos: leading, len: name.length, original: s0,
            expected: "an alias among #{SPECIAL_ALIASES.join(', ')}",
            message: "unknown cron alias #{name.inspect}, expected one of " +
              SPECIAL_ALIASES.join(', '),
            syntax: 'cron')
        end

        if Fugit::Cron::SPECIALS[name] == :reboot
          return make(
            :unsupported_alias, :timezone,
            pos: leading, len: name.length, original: s0,
            expected: "an alias other than @reboot " +
              "(#{(SPECIAL_ALIASES - [ '@reboot' ]).join(', ')})",
            message: "'@reboot' is not a schedule, it cannot be expanded " +
              'into a cron expression',
            syntax: 'cron')
        end

        ss = s.split(/\s+/, 2)
        s = [ Fugit::Cron::SPECIALS[ss[0]], *ss[1..-1] ].join(' ')
        alias_map = [ leading, name, ss[0] ]
        aliased = true
      end

      return nil if safe_parse(s, opts)

      interpretations = build(s, s0, leading, alias_map, opts, aliased: !!aliased)

      pick(s0, interpretations)
    end

    # Internal: analyze a cron-shaped string already produced by another
    # parser (nat), mapping generated-token failures back to `s0`.
    #
    def analyze_generated(gen, s0, leaves, opts={})

      return nil if safe_parse(gen, opts)

      leading = 0
      interps = build(gen, s0, leading, nil, opts, remap: leaves, gen: gen)

      d = pick(s0, interps)
      d
    end

    protected

    def safe_parse(s, opts)

      Fugit::Cron.parse(s, opts)
    rescue StandardError
      nil
    end

    def make(code, field, h={})

      field = Array(field)
      type = h.delete(:type) || :cron

      h[:fields] ||= field
      h[:syntax] ||= type.to_s

      unless h[:message]
        h[:message] = default_message(code, field, h)
      end
      h[:expected] ||= expected_for(field.first, code)

      Fugit::Diagnostic.new(type, code, h)
    end

    def expected_for(field, code)

      case code
      when :missing_field then 'one or more cron fields separated by spaces'
      when :invalid_timezone
        'an IANA timezone name (like "America/New_York"), "UTC", or an ' +
          'offset like "+09:00"'
      when :unexpected_token then 'end of input'
      else EXPECTED[field]
      end
    end

    def default_message(code, fields, h)

      f = fields.collect { |ff| FIELD_LABELS[ff] || ff.to_s }.join(' and ')
      got = h[:details] ? " (#{h[:details]})" : ''

      case code
      when :out_of_range then "out of range value for the #{f} field#{got}"
      when :invalid_value then "invalid value for the #{f} field#{got}"
      when :unexpected_token
        "unexpected token#{h[:slice] ? " #{h[:slice].inspect}" : ''}#{got}"
      when :missing_field then "missing #{f} field#{got}"
      when :invalid_timezone then "unknown or invalid timezone#{got}"
      when :invalid_step then "step value#{got} must be 1 or greater"
      when :mixed_signs
        'range bounds must both be positive or both be negative' + got
      when :never_occurs
        'this cron never occurs, the day-of-month values do not exist ' +
          'for the given months'
      when :ambiguous then 'the expression can be read as multiple crons'
      else "invalid cron #{f} field#{got}"
      end
    end

    # Split the (stripped, expanded) string into tokens with absolute
    # spans inside that string.
    #
    def tokens_with_spans(s)

      toks = []
      s.scan(/\S+/) do
        i = Regexp.last_match.begin(0)
        toks << [ Regexp.last_match[0], i, i + Regexp.last_match[0].length ]
      end
      toks
    end

    def looks_like_timezone?(tok)

      !! tok.match?(TZ_LIKE) && ! tok.match?(/\A[-+]?\d+\z/)
    end

    def build(s, s0, leading, alias_map, opts, remap: nil, gen: nil, aliased: false)

      toks = tokens_with_spans(s)

      tz_index =
        toks.index { |t, _, _| looks_like_timezone?(t) }

      core = tz_index ? toks[0...tz_index] : toks
      tz = tz_index ? toks[tz_index] : nil
      extras = tz_index ? toks[(tz_index + 1)..-1].to_a : []

      # An expanded alias always fills the classic five fields; any token
      # after it is therefore a trailing extra, never a seconds field.
      #
      if aliased && core.length > 5
        extras = core[5..-1] + extras
        core = core[0, 5]
      end

      interpretations = []

      # Whether the token count itself leaves the layout undecided.
      # 5 core tokens are always classic; 6 (without a tz) could be
      # seconds-cron OR classic-cron + trailing token.
      #
      ambiguous_layout =
        tz.nil? && (core.length == 6)

      each_layout(core.length, ambiguous_layout) do |layout, kind|

        d = analyze_layout(
          layout, kind, s, s0, leading, alias_map, core, tz, extras, remap,
          gen, opts)

        interpretations << [ kind, d ] if d
      end

      interpretations
    end

    # Layouts worth testing for a given count of core tokens.
    # Returns [ layout, kind ] where kind ranks the guess.
    #
    def each_layout(count, ambiguous)

      case count
      when 5 then yield(CLASSIC, :classic)
      when 6
        if ambiguous
          yield(SECONDS, :seconds); yield(CLASSIC, :classic)
        else
          yield(SECONDS, :seconds)
        end
      else
        # fewer than 5 core fields: classic (the standard) only
        yield(CLASSIC, :classic)
      end
    end

    def analyze_layout(
      layout, kind, s, s0, leading, alias_map, core, tz, extras, remap, gen,
      opts)

      issue = nil

      # 1. lex each token for its field, first failing field wins
      #
      core.each_with_index do |(tok, a, b), i|

        field = layout[i]
        next unless field

        unless lex_ok?(field, tok)
          issue = field_issue(field, tok, a, b)
          break
        end
      end

      # 2. timezone
      #
      issue ||= timezone_issue(tz)

      # 3. extra trailing tokens
      #
      if issue.nil? && extras.any?
        tok, a, b = extras.first
        issue =
          if looks_like_timezone?(tok)
            [ :invalid_timezone, :timezone, a, b,
              "unexpected second timezone #{tok.inspect}" ]
          else
            [ :unexpected_token, layout.last, a, b, nil ]
          end
      end

      # 4. missing fields
      #
      if issue.nil? && core.length < layout.length

        missing = layout[core.length..-1]

        at = core.any? ? core.last[2] : 0
        issue = [ :missing_field, missing, at, at, nil ]
      end

      # 5. semantic validation over whatever parsed structurally.
      # Run whenever the field sets are complete and there are no extra
      # tokens (a trailing timezone is fine).
      #
      if issue.nil? && core.length == layout.length && extras.empty?

        issue = semantic_issue(s, core, layout, kind, opts)
      end

      return nil unless issue

      code, field, a, b, detail = issue

      to_diagnostic(
        code, field, a, b, s0, leading, alias_map, remap, gen, detail)
    end

    def lex_ok?(field, tok)

      inp = ::Raabro::Input.new("#{tok} ", {})
      t = Fugit::Cron::Parser.send(WRAPPERS[field], inp)

      t.result == 1 && t.length >= tok.length
    end

    def field_issue(field, tok, a, b)

      # Try the bounds: split the token into comma-separated atoms and
      # look for a leading number out of the field range.
      #
      min, max = BOUNDS[field]

      atoms = token_atoms(tok)
      bad = atoms.find { |at, aa, bb| numeric_out_of_range?(at, min, max) }

      if bad
        at, aa, bb = bad
        return [ :out_of_range, field, a + aa, a + bb,
                 "expected #{min}..#{max}, got #{at}" ]
      end

      # A weekday "#n"/"#last" occurrence: n must be within -5..5.
      #
      if field == :weekdays
        hm = tok.match(/#(-?\d+)/)
        if hm
          n = hm[1].to_i
          unless n.between?(-5, 5)
            return [
              :out_of_range, field, a + hm.begin(0), a + hm.end(0),
              "weekday occurrence #{n} expected -5..5" ]
          end
        end
      end

      # Otherwise it is a malformed token. Determine how much of the
      # token the field wrapper could consume and point at the remaining
      # (unconsumed) characters.
      #
      inp = ::Raabro::Input.new("#{tok} ", {})
      t = Fugit::Cron::Parser.send(WRAPPERS[field], inp)

      consumed =
        if t.result == 1
          # the wrapper consumed the token plus a trailing separator
          [ t.length - 1, tok.length ].min
        else
          deepest_fail_offset(t) || 0
        end

      # If the failure sits at the end of a numeric prefix that is itself
      # well-formed (e.g. "25あ" for the hour field, where "25" alone is a
      # valid number), advance to the end of that prefix so the actual
      # offending character is highlighted.
      #
      tail = tok[consumed..-1].to_s
      if (m = tail.match(/\A-?\d+/)) && m.end(0) > 0
        prefix = m[0].to_i
        if prefix.between?(BOUNDS[field][0], BOUNDS[field][1])
          consumed += m.end(0)
        end
      end

      consumed = [ consumed, tok.length ].min

      start = a + consumed
      finish = start < b ? b : start

      [ :invalid_value, field, start, finish, "not a valid #{field} value" ]
    end

    def token_atoms(tok)

      a = []
      tok.scan(/[^,\s\/\-~#&]+/) do
        w = Regexp.last_match[0]
        i = Regexp.last_match.begin(0)
        a << [ w, i, i + w.length ]
      end
      a
    end

    def numeric_out_of_range?(word, min, max)

      return false unless word.match?(/\A-?\d+\z/)

      n = word.to_i

      if min == 1
        n < min || n > max # negative handled elsewhere ("L"), flag OOR low
      else
        n < min || n > max
      end
    end

    def deepest_fail_offset(tree)

      best = nil
      walk =
        lambda do |t|
          if t.result == 0 && t.children.empty?
            best = t.offset if best.nil? || t.offset > best
          end
          t.children.each { |c| walk.call(c) }
        end
      walk.call(tree)
      best
    end

    def timezone_issue(tz)

      return nil unless tz

      name, a, b = tz

      return nil if ::EtOrbi.get_tzone(name)

      [ :invalid_timezone, :timezone, a, b, "no timezone named #{name.inspect}" ]
    end

    def semantic_issue(s, core, layout, kind, opts)

      # Invalid step: an explicit "/0" or "/<negative>" in a field token.
      #
      layout.each_with_index do |field, i|
        tok = core[i]
        next unless tok
        word = tok[0]

        if word.split(',').any? { |at| at.match?(%r{/[-+]?0+\z}) }
          return [ :invalid_step, field, tok[1], tok[2], nil ]
        end
      end

      # Mixed signs: a range whose bounds have opposite signs, like
      # "-5-3" or "3--5", in a field that allows negatives (dom).
      #
      layout.each_with_index do |field, i|
        tok = core[i]
        next unless tok
        word = tok[0]

        next unless field == :monthdays

        mm = word.match(/(-?\d+)\s*-\s*(-?\d+)/)
        if mm
          a0, a1 = mm[1].to_i, mm[2].to_i
          if (a0 < 0 && a1 >= 0) || (a1 < 0 && a0 >= 0)
            return [
              :mixed_signs, field, tok[1], tok[2],
              "range #{mm[0].inspect} mixes negative and positive bounds" ]
          end
        end
      end

      # Never occurs: e.g. "day 31 of February". Mirrors
      # Cron#compact_month_days, which empties the month/day sets when no
      # listed day can fall in a listed month.
      #
      never = never_occurs_issue(core, layout)
      return never if never

      nil
    end

    # Parse the month and monthday tokens into integer sets (positive
    # days only) and check whether any combination can exist.
    #
    def never_occurs_issue(core, layout)

      mi = layout.index(:months)
      di = layout.index(:monthdays)

      return nil unless mi && di

      mtok = core[mi]
      dtok = core[di]

      return nil unless mtok && dtok

      months = expand_ints(mtok[0], 1..12, 12, 1..12)
      days =
        expand_ints(dtok[0], 1..31, 31, 1..31)
          .select { |d| d > 0 }

      return nil if months.nil? || days.nil?
      return nil if months.empty? || days.empty?

      possible =
        months.any? { |m| days.any? { |d| d <= Fugit::Cron::MAXDAYS[m] } }

      return nil if possible

      [
        :never_occurs, [ :monthdays, :months ],
        dtok[1], mtok[2],
        'none of the day-of-month values exist in any listed month' ]
    end

    # Expand a cron atom list token into integer values, honoring
    # ranges ("1-3"), steps ("*/2", "1-10/2"), and commas. Returns nil
    # for "*", an empty array if nothing matches.
    #
    def expand_ints(word, range, max, _bounds)

      return nil if word.strip == '*'

      out = []

      word.split(',').each do |atom|

        if (m = atom.match(/\A(?:\*|(-?\d+)(?:-(-?\d+))?)(?:\/(-?\d+))?\z/))

          sta = m[1] ? m[1].to_i : range.first
          edn = m[2] ? m[2].to_i : (m[1] ? sta : range.last)
          sl = m[3] ? m[3].to_i : 1

          next if sl < 1

          (sta..edn).step(sl) { |v| out << v }
        end
      end

      out
    end

    # Convert an issue located in the expanded string into a Diagnostic
    # relative to the original string, applying alias remapping and/or
    # generated-cron (nat) remapping.
    #
    def to_diagnostic(
      code, field, a, b, s0, leading, alias_map, remap, gen, detail)

      pos, len =
        if remap
          remap_span(code, field, a, b, remap, gen, s0)
        else
          [ leading + a, b - a ]
        end

      pos, len = apply_alias(pos, len, alias_map, s0) if alias_map

      slice0 = (pos && s0) ? s0[pos, len] : nil

      h = {
        pos: pos, len: len, original: s0, type: :cron,
        details: detail, slice: slice0 }

      d = make(code, field, h)
      d
    end

    def apply_alias(pos, len, alias_map, s0)

      leading, name, _orig = alias_map

      abs = pos - leading # position within expanded

      if abs < name.length
        # lands on the expanded schedule -> highlight the alias token
        [ leading, name.length ]
      else
        # lands on a token following the alias; the expanded schedule is
        # the 5-field value of the alias, immediately followed by the
        # remaining original tokens.
        sched_len = Fugit::Cron::SPECIALS[name].length
        delta = name.length - sched_len
        [ leading + (abs + delta), len ]
      end
    end

    # Map an issue in a generated cron back onto the nat source.
    #
    def remap_span(code, field, a, b, leaves, gen, s0)

      if code == :invalid_timezone

        t = (leaves[:tz] || []).first
        return [ t.offset, t.length ] if t
      end

      gen_tok = gen[a...b].to_s

      if code == :missing_field
        last = (leaves.values.flatten.max_by(&:offset) rescue nil)
        return last ? [ last.offset + last.length, 0 ] : [ 0, 0 ]
      end

      # find a leaf matching the offending generated token's literal
      cand = find_source_leaf(gen_tok, leaves)

      return [ cand.offset, cand.length ] if cand

      [ a, [ b - a, 1 ].max ]
    end

    def find_source_leaf(gen_tok, leaves)

      word = gen_tok[/[A-Za-z0-9:]+/]
      return nil if word.nil? || word.empty?

      # 1. exact, case-insensitive match among value-bearing leaves
      #
      names = %i[ count dmin monthday omonthday weekday digital_h simple_h
                  named_h named_m tz offset_count ]
      names.each do |n|
        (leaves[n] || []).each do |t|
          return t if t.string.strip.downcase == word.downcase
        end
      end

      # 2. a leaf that contains the word
      #
      all = leaves.values.flatten.sort_by { |t| t.offset }
      all.find { |t| t.string.include?(word) } ||
        all.find { |t| word.include?(t.string.strip) && t.length > 0 }
    end

    # Only the 6-token-without-timezone shape is truly ambiguous: it can
    # be a seconds cron or a classic cron whose last token is trailing.
    # In that case we prefer the reading that parses furthest (no early
    # lex error), but attach the other reading as an `:ambiguous`
    # candidate so the UI can offer both fixes.
    #
    def pick(s0, interpretations)

      return generic(s0) if interpretations.empty?

      by_kind =
        interpretations
          .each_with_object({}) { |(kind, d), h| (h[kind] ||= []) << d }

      classics = by_kind[:classic] || []
      seconds = by_kind[:seconds] || []

      if classics.any? && seconds.any?

        c = classics.min_by { |d| - rank(d) }
        s = seconds.min_by { |d| - rank(d) }

        best, alt =
          if rank(s) > rank(c) then [ s, c ] else [ c, s ] end

        if same_issue?(best, alt)
          return best
        end

        cands =
          [ best, alt ]
            .uniq { |d| [ d.code, (d.fields || []).first, d.pos ] }

        return Fugit::Diagnostic.new(
          :cron, :ambiguous,
          original: s0,
          pos: best.pos, len: best.len,
          fields: best.fields,
          message:
            "the 6 fields can be read as a seconds cron " +
            '"sec min hour dom mon dow" (error at the ' +
            "#{(seconds.include?(best) ? best : alt).fields.join('/')} " +
            "field) or as a 5-field cron " +
            '"min hour dom mon dow" followed by an extra token ' +
            "(error at the " +
            "#{(seconds.include?(best) ? alt : best).fields.join('/')} " +
            'field); add/remove a field or append a timezone to decide',
          expected:
            '"sec min hour dom mon dow", or "min hour dom mon dow" ' +
              'optionally followed by a timezone',
          details: best.details,
          candidates: cands)
      end

      (classics + seconds).min_by { |d| - rank(d) }
    end

    def same_issue?(a, b)

      a && b && a.code == b.code &&
        (a.fields || []) == (b.fields || []) &&
        a.pos == b.pos
    end

    def rank(d)

      case d.code
      when :never_occurs then 200
      when :out_of_range, :invalid_value, :invalid_step,
           :mixed_signs, :invalid_timezone
        100 - (d.pos || 0) / 16
      when :missing_field then 30
      else 10
      end
    end

    def generic(s0)

      Fugit::Diagnostic.new(
        :cron, :unparseable,
        original: s0, pos: 0,
        message: 'not a valid cron expression',
        expected:
          '"min hour dom mon dow", optionally preceded by seconds, and ' +
          'optionally followed by a timezone')
    end
  end

  module DurationDiagnostic
    include DiagnosticHelpers

    extend self

    UNIT_TOK =
      /\A(?:y|years?|months?|w|weeks?|d|days?|h|hours?|m|min(?:ute)?s?|
          s|sec(?:ond)?s?)\z/xi.freeze

    EXPECTED_UNITS =
      'a number followed by a unit: y(ears), M/months, w(eeks), ' +
        'd(ays), h(ours), m(inutes), s(econds)'.freeze

    def diagnose(s0, opts={})

      return nil unless s0.is_a?(String)

      s = ascii_strip(s0)
      leading = lead(s0, s)

      return too_long(:duration, s0, s.length) if
        s.length > ::Fugit::MAX_INPUT_LENGTH

      return nil if safe_parse(s, opts)

      iso = upcase(s).start_with?('P')

      iso ? diagnose_iso(s, s0, leading) : diagnose_plain(s, s0, leading)
    end

    protected

    def upcase(s); s.upcase; end

    def safe_parse(s, opts)

      Fugit::Duration.parse(s, opts)
    end

    def mk(code, h)

      h[:type] = :duration
      h[:syntax] ||= 'duration'
      h[:fields] ||= []
      h[:message] ||= default_msg(code, h)
      h[:expected] ||= expected_for(code)

      Fugit::Diagnostic.new(:duration, code, h)
    end

    def expected_for(code)

      case code
      when :invalid_unit then EXPECTED_UNITS
      when :unexpected_token
        'a number with a unit, or a separator (space, comma, "and")'
      when :missing_field
        'a duration like "1h30m", "12 minutes", or ISO-8601 like "PT1H30M"'
      else 'a duration like "1h30m" or "PT1H30M"'
      end
    end

    def default_msg(code, h)

      case code
      when :invalid_unit
        w = h[:details]
        "unknown duration unit#{" #{w.inspect}" if w}"
      when :unexpected_token
        w = h[:details]
        "unexpected token#{" #{w.inspect}" if w}"
      when :missing_field then 'missing number and/or unit'
      else 'not a valid duration expression'
      end
    end

    def diagnose_plain(s, s0, leading)

      # Character-aware tokenization so multibyte junk is located
      # correctly. Each chunk is a separator, a number, and/or a unit.
      #
      pos = 0
      len = s.length

      while pos < len

        if (m = s.match(/\G(?:and|[ \t,]+)/i, pos))
          pos += m[0].length
          next
        end

        start = pos

        s.match(/\G[-+]/, pos) && pos = $~.end(0)
        num = s.match(/\G(?:\d+(?:\.\d*)?|\.\d+)/, pos)
        pos += num[0].length if num
        unit = s.match(/\G[A-Za-z]+/, pos)

        if unit
          us, ue, word = unit.begin(0), unit.end(0), unit[0]
          pos = ue

          unless word.match?(UNIT_TOK)
            return mk(:invalid_unit,
              pos: leading + us, len: ue - us,
              original: s0, details: word)
          end

          unless num
            # letters without a leading number
            return mk(:missing_field,
              pos: leading + start, len: ue - start, original: s0)
          end

          next
        end

        if num

          # a number glued to a non-ASCII word character (e.g. "30あ")
          # cannot be a plain unit; point at that character
          if (gl = s.match(/\G\S/, pos))
            ch = gl[0]
            if ! ch.match?(/[A-Za-z]/)
              return mk(:unexpected_token,
                pos: leading + pos, len: ch.length, original: s0,
                details: ch)
            end
          end

          rest = s[pos..-1].to_s
          # a bare number that ends the string is accepted (seconds);
          # a bare number followed by more text is missing a unit
          if rest.match?(/\A[ \t,]*\z/)
            # whole string (apart from separators) is a bare number,
            # which fugit accepts -> shouldn't reach here
            break
          end
          return mk(:missing_field,
            pos: leading + start, len: pos - start, original: s0,
            details: "number #{num[0]} without a unit")
        end

        # lone sign or any other character (incl. multibyte)
        cl = (s[pos] || s[-1] || '').length
        return mk(:unexpected_token,
          pos: leading + pos, len: cl, original: s0,
          details: s[pos, cl])
      end

      # Nothing pinpointed: fall back to the parser's error offset.
      tuple =
        Fugit::Duration::Parser.parse(
          s, rewrite: false, prune: false, error: true)

      off = tuple.is_a?(Array) ? [ tuple[2], s.length ].min : s.length

      mk(:unparseable,
        pos: leading + off,
        len: off >= s.length ? 0 : s.length - off,
        original: s0)
    end

    def diagnose_iso(s, s0, leading)

      u = upcase(s)

      # "P" alone is accepted by fugit (== 0s); anything else failing...
      #
      # invalid unit/designator (structural P/T are allowed letters)
      bad_letter =
        u.each_char.with_index.find do |c, _|
          c.match?(/[A-Za-z]/) && ! c.match?(/[PYMWDTHS]/)
        end
      if bad_letter
        c, i = bad_letter
        return mk(:invalid_unit,
          pos: leading + i, len: 1, original: s0, details: c)
      end

      if (m = u.match(/(\d+)(?![YMWDHS])/))
        # a run of digits not immediately followed by a designator:
        # the duration element is missing its Y/M/W/D/H/S unit
        i = m.begin(1)
        j = i + m[1].length
        return mk(:missing_field,
          pos: leading + i, len: j - i, original: s0,
          details: "number #{m[1]} without a unit designator")
      end

      # something like "PT" or "P": missing a value+designator
      if u.match?(/\A PT? \z/x)
        return mk(:missing_field,
          pos: leading + u.length, len: 0, original: s0)
      end

      tuple =
        Fugit::Duration::IsoParser.parse(
          u, rewrite: false, prune: false, error: true)

      off = tuple.is_a?(Array) ? tuple[2] : u.length
      off = [ off, u.length ].min

      mk(:missing_field,
        pos: leading + off,
        len: (off == u.length ? 0 : 1),
        original: s0)
    end
  end

  module NatDiagnostic
    include DiagnosticHelpers

    extend self

    def diagnose(s0, opts={})

      return nil unless s0.is_a?(String)

      s = ascii_strip(s0)
      leading = lead(s0, s)

      return too_long(:nat, s0, s.length) if
        s.length > ::Fugit::MAX_INPUT_LENGTH

      return nil if (Fugit::Nat.parse(s, opts) rescue nil)

      raw =
        Fugit::Nat::Parser.parse(
          s, rewrite: false, prune: false, error: true)

      # 1. the nat grammar itself rejected the string
      #
      if raw.is_a?(Array)

        _line, _col, off, rmsg = raw

        # For "not all input was consumed" the tuple offset is the point
        # raabro reached (often mid-token); walk back to the start of the
        # token that failed so the whole offending word is highlighted.
        #
        if rmsg && rmsg.include?('not all input')
          start = s.rindex(/[ \t]/, [ off - 1, 0 ].max)
          start = start ? start + 1 : 0
          start = off if s[start...off].to_s.strip.empty?
          off = start
        end

        return Fugit::Diagnostic.new(
          :nat, :not_natural_language,
          original: s0,
          pos: leading + off,
          len: word_len_at(s, off),
          message:
            'not a recognized natural language schedule at that position',
          expected:
            'phrases like "every day at 5pm", "every monday at noon", ' +
              '"every 15 minutes"')
      end

      return generic(s0, leading) unless raw.is_a?(::Raabro::Tree)

      leaves = gather_leaves(raw)

      # 2. the grammar matched, but the resulting cron is invalid
      #    (bad tz, out of range generated field, ambiguity, ...)
      #
      gens = generated_crons(s, opts)

      gens.each do |gen|

        cd = CronDiagnostic.analyze_generated(gen, s0, leaves, opts)
        next unless cd

        return rebrand(cd, :nat)
      end

      # 3. "at 9 to 5"-like slot-level failures and strict-mode rejections
      #
      generic(s0, leading)
    end

    protected

    def gather_leaves(tree)

      acc = {}
      walk =
        lambda do |t|
          if t.name && t.length > 0 &&
             (t.children.empty? || t.children.all? { |c| c.name.nil? })
            (acc[t.name] ||= []) << t
          end
          t.children.each { |c| walk.call(c) }
        end
      walk.call(tree)
      acc
    end

    def generated_crons(s, opts)

      slots =
        Fugit::Nat::Parser.parse(s, rewrite: true)

      return [] unless slots

      begin
        slots.to_crons({ _s: s }.merge(opts).merge(multi: true))
      rescue StandardError
      end

      slots.respond_to?(:diagnostic_crons) ? slots.diagnostic_crons : []
    end

    def word_len_at(s, off)

      m = s[off..-1].to_s.match(/\S+/)
      m ? m[0].length : 0
    end

    def rebrand(cd, type)

      Fugit::Diagnostic.new(
        type, cd.code,
        original: cd.original,
        pos: cd.pos, len: cd.len,
        fields: cd.fields,
        message: cd.message,
        expected: cd.expected,
        details: cd.details,
        candidates: cd.candidates,
        syntax: 'natural language')
    end

    def generic(s0, leading)

      Fugit::Diagnostic.new(
        :nat, :not_natural_language,
        original: s0, pos: leading, len: 0,
        message: 'not a recognized natural language schedule',
        expected:
          'phrases like "every day at 5pm", "every monday at noon", ' +
            '"every 15 minutes"',
        syntax: 'natural language')
    end
  end

  class << self

    include DiagnosticHelpers

    def diagnose_cron(s, opts={}); CronDiagnostic.diagnose(s, opts); end
    def diagnose_duration(s, opts={}); DurationDiagnostic.diagnose(s, opts); end
    def diagnose_nat(s, opts={}); NatDiagnostic.diagnose(s, opts); end

    # Diagnose `s` across the cron, duration, and natural language
    # entries. Returns nil when at least one entry parses successfully.
    #
    # The `at` entry (plain time/date strings) is also consulted so that
    # `#diagnose` stays consistent with `Fugit.parse`, which includes it.
    #
    def diagnose(s, opts={})

      return nil unless s.is_a?(String)

      opts[:at] = opts[:in] if opts.has_key?(:in)

      return nil if opts[:at] != false && parse_at(s, opts)

      tried = []

      if opts[:cron] != false
        if (r = parse_cron(s, opts))
          return nil
        else
          d = diagnose_cron(s, opts)
          tried << [ :cron, d ] if d
        end
      end

      if opts[:duration] != false
        if (r = parse_duration(s))
          return nil
        else
          d = diagnose_duration(s, opts)
          tried << [ :duration, d ] if d
        end
      end

      if opts[:nat] != false
        if (r = parse_nat(s, opts))
          return nil
        else
          d = diagnose_nat(s, opts)
          tried << [ :nat, d ] if d
        end
      end

      combine(s, tried)
    end

    protected

    def combine(s, tried)

      return unparseable(s) if tried.empty?

      scored =
        tried.map { |type, d| [ score(d), type, d ] }
          .sort_by { |sc, _, _| -sc }

      best_score, best_type, best_diag = scored.first

      # Only flag cross-entry ambiguity when another entry reaches the
      # same, genuinely specific level (a concrete value/unit/tz error,
      # not a bare "missing field" or "didn't parse as words" guess).
      #
      tied =
        scored[1..-1].select { |sc, _, d|
          sc == best_score && sc >= 80 && specific?(d) }

      if specific?(best_diag) && tied.any?
        cands =
          [ best_diag, *tied.map { |_, _, d| d } ]
        return Diagnostic.new(
          :generic, :ambiguous,
          original: s, pos: best_diag.pos, len: best_diag.len,
          fields: best_diag.fields,
          message:
            "the input could be intended as more than one kind of time " +
            "expression: #{([best_type] + tied.map { |t, _, _| t }).join(', ')}",
          expected:
            'a cron ("0 25 * * *"), a duration ("1h30m"), or natural ' +
              'language ("every day at noon")',
          candidates: cands)
      end

      best_diag
    end

    def specific?(d)

      case d.code
      when :out_of_range, :invalid_value, :invalid_step, :mixed_signs,
           :invalid_timezone, :invalid_unit, :never_occurs
        true
      else false
      end
    end

    def score(d)

      base =
        case d.type
        when :duration then 2
        when :cron then 1
        when :nat then 0
        else 0
        end

      weight =
        case d.code
        when :out_of_range, :invalid_value, :invalid_step, :mixed_signs,
             :invalid_timezone, :invalid_unit, :never_occurs
          100
        when :missing_field, :not_natural_language then 40
        else 5
        end

      # A cron "ambiguous" is already internally resolved; treat its
      # primary candidate with that candidate's weight.
      if d.code == :ambiguous && d.candidates && d.candidates.any?
        return score(d.candidates.first)
      end

      weight + base - (d.pos || 0) / 64
    end

    def unparseable(s)

      Diagnostic.new(
        :generic, :unparseable,
        original: s, pos: 0,
        message: 'no time information could be read from the input',
        expected:
          'a cron ("0 25 * * *"), a duration ("1h30m", "PT1H30M"), or ' +
            'natural language ("every day at noon")')
    end
  end
end
