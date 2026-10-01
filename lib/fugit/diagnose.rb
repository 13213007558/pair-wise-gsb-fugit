# frozen_string_literal: true

module Fugit

  # Structured parse diagnostics.
  #
  # Whereas Fugit.parse / parse_cron / parse_duration / parse_nat only
  # return a parse result (or nil), or, for the do_parse_ variants, raise
  # a generic ArgumentError, the diagnose_ variants return a structured
  # report that points at the place that made the input invalid, names
  # the field involved and states what value or syntax was expected.
  #
  # The diagnosis always works on the *original* string passed by the
  # caller: surrounding whitespace is skipped for parsing but every
  # reported position is a character offset into that original string,
  # and cron aliases ("@daily", ...) are not expanded before locating
  # issues (errors in expanded text map back to the alias token).
  #
  module Diagnose

    # A single structural problem found while diagnosing an input.
    #
    class Issue

      ATTRIBUTES = %i[
        kind field format position length line column snippet message
        expected got interpretations ].freeze

      attr_reader(*ATTRIBUTES)

      def initialize(kind, field, position, length, message, opts={})

        @kind = kind
          # :invalid_timezone
          # :out_of_range
          # :missing_field
          # :syntax
          # :unknown_alias
          # :unexpected_input
          # :ambiguous
        @field = field
          # :seconds, :minutes, :hours, :monthdays, :months, :weekdays,
          # :timezone, :duration, :nat ... (nil when not field-specific)
        @format = opts[:format]
          # :cron, :duration, :nat (set for merged generic reports)
        @position = position
          # char (codepoint) offset into the *original* input
        @length = length
          # char length of the offending segment, 0 for a caret-only spot
        @message = message

        @expected = opts[:expected]
        @got = opts[:got]
        @snippet = opts[:snippet]
        @line = opts[:line]
        @column = opts[:column]
        @interpretations = opts[:interpretations]
      end

      def range; [ @position, @length ]; end

      def to_h

        ATTRIBUTES
          .inject({}) { |h, k|
            v = send(k); h[k] = v unless v.nil?; h }
      end

      def inspect

        a = [ @kind.inspect, @field&.inspect, @position, @length ]
        "(issue #{a.compact.join(' ')})"
      end
    end

    # The result of diagnosing an input for one format (cron, duration,
    # nat) or for the generic Fugit.diagnose entry point.
    #
    class Report

      attr_reader :format, :input, :issues, :interpretations, :ambiguity

      def initialize(format, input)

        @format = format # :cron, :duration, :nat, nil for Fugit.diagnose
        @input = input
        @issues = []
        @interpretations = []
      end

      # Valid means no issue at all (no parse error and no ambiguity).
      # #parseable? answers the narrower question "would the legacy
      # parse accept this?" (a phrase resolved to its first cron is
      # still parseable even when ambiguous).
      #
      def valid?; @issues.empty? && @ambiguity.nil?; end
      def invalid?; ! valid?; end
      def parseable?; @issues.empty?; end
      def ambiguous?; ! @ambiguity.nil?; end
      def hard_invalid?; ! @issues.empty?; end

      def issue?(*kinds)

        kinds = kinds.flatten
        @issues.any? { |i| kinds.empty? || kinds.include?(i.kind) }
      end

      # Record a non-fatal ambiguity (several distinct readings of a
      # string that the legacy parser silently collapses to one).
      #
      def note_ambiguity(field, pos, len, message, opts={})

        opts = opts.dup
        opts[:snippet] ||= compute_snippet(@input, pos, len)
        if @input.is_a?(String) && pos
          opts[:line], opts[:column] = line_and_column(@input, pos)
        end

        @ambiguity = Issue.new(:ambiguous, field, pos, len, message, opts)
        self
      end

      def add_issue(kind, field, pos, len, message, opts={})

        opts = opts.dup
        opts[:snippet] ||= compute_snippet(@input, pos, len)
        if @input.is_a?(String) && pos
          opts[:line], opts[:column] = line_and_column(@input, pos)
        end

        @issues << Issue.new(kind, field, pos, len, message, opts)

        self
      end

      def add_interpretation(interp)

        @interpretations << interp unless @interpretations.include?(interp)
        self
      end

      # Add an issue coming from a per-format report, tagging it with
      # that format.
      #
      def merge_issue(issue, format)

        opts = issue.to_h
        opts[:format] = format
        @issues << Issue.new(
          issue.kind, issue.field, issue.position, issue.length,
          issue.message, opts)
        self
      end

      def to_h

        h = {}
        h[:format] = @format if @format
        h[:input] = @input
        h[:valid] = valid?
        h[:parseable] = parseable?
        h[:issues] = @issues.collect(&:to_h) unless @issues.empty?
        h[:ambiguity] = @ambiguity.to_h if @ambiguity
        unless @interpretations.empty?
          h[:interpretations] = @interpretations
        end
        h
      end

      alias to_hash to_h

      def inspect

        "(diagnose report #{@format.inspect} valid=#{valid?} " +
        "issues=#{@issues.size})"
      end

      protected

      def compute_snippet(input, pos, len)

        return nil unless input.is_a?(String) && pos
        return nil if pos > input.length

        len ||= 0
        a = [ pos - 4, 0 ].max
        b = [ pos + len + 4, input.length ].min

        { before: input[a...pos],
          segment: len > 0 ? input[pos, len] : '',
          after: input[(pos + len)...b] }
      end

      def line_and_column(s, pos)

        head = s[0, pos]
        nl = head.rindex("\n")
        [ head.count("\n") + 1, nl ? pos - nl : pos + 1 ]
      end
    end

    # Map an offset/length expressed in a rewritten string back to the
    # core (stripped, but otherwise original) string.
    #
    # `mapping` is an Array with one entry per char of the rewritten
    # string, holding the index of that char in the core string (nil for
    # chars introduced by the rewrite).  A nil mapping is identity.
    #
    def self.remap(position, length, mapping=nil)

      return [ position, length ] unless mapping

      ps = mapping[position]
      ps ||= mapping[0...position].compact.last || 0

      if length && length > 0
        pe = nil
        i = position
        while i < mapping.length && i < position + length
          pe = mapping[i] if mapping[i]
          i += 1
        end
        pe ||= ps
        return [ ps, pe - ps + 1 ] if pe >= ps
      end

      [ ps, length || 0 ]
    end
  end

  class << self

    def diagnose_cron(s, opts={}); CronDiagnoser.new(s, opts).run; end
    def diagnose_duration(s, opts={}); DurationDiagnoser.new(s, opts).run; end
    def diagnose_nat(s, opts={}); NatDiagnoser.new(s, opts).run; end

    # Diagnose an input against the cron, duration, and nat entry points.
    #
    def diagnose(s, opts={})

      report = Diagnose::Report.new(nil, s)

      unless s.is_a?(String)
        report.add_issue(
          :syntax, nil, 0, 0,
          "expected a String, got a #{s.class} instance",
          got: s.class)
        return report
      end

      rs = []
      rs << diagnose_cron(s, opts) unless opts[:cron] == false
      rs << diagnose_duration(s, opts) unless opts[:duration] == false
      rs << diagnose_nat(s, opts) unless opts[:nat] == false

      valid = rs.select(&:valid?)

      if valid.size > 1
        formats = valid.collect(&:format)
        report.add_issue(
          :ambiguous, nil, 0, 0,
          'ambiguous input, it can be interpreted as ' +
          formats.collect(&:to_s).join(' and '),
          expected: 'one single time expression format',
          got: formats)
        valid.each { |r| report.add_interpretation(r.format) }
      elsif valid.empty?
        rs.each { |r| r.issues.each { |i| report.merge_issue(i, r.format) } }
      end

      report
    end
  end

  # Common base for the per-format diagnosers.  Subclasses implement
  # #diagnose_core and register issues through #add.
  #
  class Diagnoser

    FORMAT = nil
    EMPTY_EXPECTED = 'a time expression'

    def initialize(s, opts={})

      @s0 = s
      @opts = opts || {}
      @report = Fugit::Diagnose::Report.new(self.class::FORMAT, s)
    end

    def run

      if ! @s0.is_a?(String)
        @report.add_issue(
          :syntax, nil, 0, 0,
          "expected a String, got a #{@s0.class} instance",
          got: @s0.class)
        return @report
      end

      lead = @s0[/\A[[:space:]]*/].length
      trail = @s0[/[[:space:]]*\z/].length
      core_end = @s0.length - trail

      if lead >= core_end

        return @report if empty_input_valid?

        @report.add_issue(
          :missing_field, nil, @s0.length, 0,
          'empty input, expected ' + self.class::EMPTY_EXPECTED,
          expected: self.class::EMPTY_EXPECTED)
        return @report
      end

      @lead = lead
      @core = @s0[lead, core_end - lead]

      diagnose_core

      @report
    end

    protected

    # Whether an empty (whitespace-only) input is valid for this
    # format.  Only the duration format treats it as zero seconds.
    #
    def empty_input_valid?; false; end

    attr_reader :core

    # Register an issue located in the parsed string.  By default the
    # parsed string is the stripped core; positions are translated back
    # to the original string.  `mapping` (see Diagnose.remap) is used
    # when the parsed string is a rewritten form of the core (cron
    # @aliases).
    #
    def add(kind, field, pos, len, message, mapping=nil, extra={})

      pos, len = Fugit::Diagnose.remap(pos, len, mapping)

      @report.add_issue(
        kind, field, @lead + pos, len, message, extra)
    end
  end

  # Cron diagnoser.
  #
  # The cron grammar has two interpretations joined in an alt:
  #  * the "second" cron (6 fields, sec min hou dom mon dow [tz])
  #  * the "classic" cron (5 fields, min hou dom mon dow [tz])
  #
  # Each interpretation is diagnosed independently.  Issues are tagged
  # with the interpretation they belong to so a UI can tell a
  # "missing field" (5 fields read as a second cron) from an
  # "out of range" (the same 5 fields read as a classic cron).
  #

  # Cron diagnoser.
  #
  # The cron grammar has two interpretations joined in an alt:
  #  * the "second" cron (6 fields, sec min hou dom mon dow [tz])
  #  * the "classic" cron (5 fields, min hou dom mon dow [tz])
  #
  # Each interpretation is diagnosed independently.  Issues are tagged
  # with the interpretation they belong to, so a UI can tell a
  # "missing field" (5 fields read as a second cron) from an
  # "out of range" (the same 5 fields read as a classic cron).
  #
  class CronDiagnoser < Diagnoser

    # Minimal container joining the two independently-parsed cron
    # interpretations (6-field second cron and 5-field classic cron),
    # exposing only the tree surface the diagnoser walks (#children).
    #
    class BranchSet

      attr_reader :children, :length

      def initialize(children, length)

        @children = children
        @length = length
      end

      def result

        @children.any? { |c| c.result == 1 } ? 1 : 0
      end
    end

    FORMAT = :cron
    EMPTY_EXPECTED =
      'a cron expression, like "0 9 * * mon" or "@daily"'

    FIELD_INFO = {
      sec: { field: :seconds,   name: 'second',       min: 0, max: 59 },
      min: { field: :minutes,   name: 'minute',       min: 0, max: 59 },
      hou: { field: :hours,     name: 'hour',         min: 0, max: 23 },
      dom: { field: :monthdays, name: 'day of month', min: 1, max: 31 },
      mon: { field: :months,    name: 'month',        min: 1, max: 12 },
      dow: { field: :weekdays,  name: 'day of week',  min: 0, max: 7 },
    }.freeze

    protected

    def diagnose_core

      if @core.length > ::Fugit::MAX_INPUT_LENGTH
        add(:syntax, nil, 0, @core.length,
          "input too long for a cron string, #{@core.length} " +
          "> #{::Fugit::MAX_INPUT_LENGTH} characters",
          nil, expected: "at most #{::Fugit::MAX_INPUT_LENGTH} characters")
        return
      end

      alias_name, alias_expansion = split_alias

      if alias_name && alias_expansion == :reboot
        add(:syntax, nil, 0, alias_name.length,
          "#{alias_name.inspect} is a recognized alias but it is not a " +
          'time schedule (it cannot be turned into a cron expression)',
          nil,
          expected: 'a time schedule alias such as @daily or a cron ' +
                    'expression',
          got: alias_name)
        return
      end

      if alias_name && ! alias_expansion
        add(:unknown_alias, nil, 0, alias_name.length,
          "unknown cron alias #{alias_name.inspect}",
          nil,
          expected: 'one of ' +
            Fugit::Cron::SPECIALS.keys.collect(&:inspect).join(', '),
          got: alias_name)
        return
      end

      parsed = alias_expansion || @core
      @mapping =
        alias_expansion ? build_alias_mapping(parsed, alias_name) : nil

      return if (Fugit::Cron.parse(@s0, @opts) rescue nil)

      # Parse each interpretation independently: raabro's `alt` prunes
      # a losing sibling, but a branch that merely loses the syntactic
      # race may still carry the most useful semantic error (a 5-field
      # hour out of range versus a 6-field missing day-of-week).
      #
      scron = parse_branch(:second_cron, parsed)
      ccron = parse_branch(:classic_cron, parsed)

      tree = BranchSet.new([ scron, ccron ].compact, parsed.length)

      before = @report.issues.size

      diagnose_branch(tree, :scron, parsed)
      diagnose_branch(tree, :ccron, parsed)

      if @report.issues.size == before
        et = deepest_failure(tree)
        add(:syntax, nil, et.offset, [ et.length, 1 ].max,
          'invalid cron syntax near here', @mapping,
          expected: 'a valid cron expression')
      end
    end

    # Parse one cron interpretation (6-field second cron or 5-field
    # classic cron) directly, bypassing raabro's alt pruning so the
    # sibling survives for independent diagnosis.
    #
    def parse_branch(parser, parsed)

      node = Fugit::Cron::Parser.send(parser, Raabro::Input.new(parsed))
      node.name = (parser == :second_cron ? :scron : :ccron)

      # A direct branch call lacks the `all` wrapper: a branch that did
      # not consume the whole input (e.g. dow matched "6" of "60") is a
      # syntactic failure for diagnosis purposes.
      node.result = 0 if node.result == 1 && node.length < parsed.strip.length

      node
    end

    # [ alias_name_or_nil, expanded_string_or_nil ]
    #
    def split_alias

      return [ nil, nil ] unless @core[0, 1] == '@'

      parts = @core.split(/[[:space:]]+/, 2)
      head = parts.first
      exp = Fugit::Cron::SPECIALS[head]

      return [ head, nil ] unless exp

      # @reboot is a recognized alias but not a time schedule; there
      # is no cron expansion to diagnose.
      return [ head, :reboot ] if exp == :reboot

      [ head, [ exp, parts[1] ].compact.join(' ') ]
    end

    # Per-char mapping from the expanded string back to the core.
    #
    # The expansion prefix (e.g. "0 0 * * *" for "@daily") maps onto
    # the alias token; the expansion is joined to the remaining core
    # tail with a single space.  The tail itself aligns with the core
    # right after the alias token.
    #
    def build_alias_mapping(expanded, alias_name)

      map = Array.new(expanded.length)
      al = alias_name.length
      core = @core

      # Tail in the core: first non-space after the alias token.
      ci = al
      ci += 1 while ci < core.length && core[ci, 1] =~ /[[:space:]]/

      # Tail in the expanded string: find the joining space right
      # before the tail, i.e. the last whitespace run of the prefix
      # followed by the same tail text.
      tail_core = ci < core.length ? core[ci..-1] : ''
      ei = tail_start_in_expansion(expanded, tail_core)

      # Expansion prefix (up to the tail) maps onto the alias token.
      (0...ei).each { |k| map[k] = [ k, al - 1 ].min }

      # Align tails.
      while ei < expanded.length && ci < core.length
        if expanded[ei, 1] == core[ci, 1]
          map[ei] = ci
          ei += 1; ci += 1
        elsif core[ci, 1] =~ /[[:space:]]/
          ci += 1
        else
          map[ei] = ci; ei += 1
        end
      end

      map
    end

    # Locate where the core tail begins inside an expanded alias
    # string.  The expanded string is "<expansion><space><tail>"; the
    # joining is exactly one space and the tail is copied verbatim, so
    # the expanded string ends with the tail (its internal whitespace
    # was not collapsed, only the single alias/tail join was added).
    #
    def tail_start_in_expansion(expanded, tail_core)

      return expanded.length if tail_core.empty?

      # expanded == exp + ' ' + tail, so char-align from the end.
      te = expanded.length
      tc = tail_core.length
      ei = te - tc

      # Guard: verify the suffix really matches (it should, by
      # construction), otherwise fall back to length.
      expanded[ei, tc] == tail_core ? ei : expanded.length
    end

    # All tree walks are scoped to a single alt branch so that, say,
    # the ccron failure cannot be located by reading a node belonging
    # to the scron attempt.
    #
    def branch_node(tree, name)

      tree.children.find { |c| c.name == name }
    end

    # Field list nodes are direct children (named :sec, :min, ...) of
    # the branch's wrapper nodes (lsec_, lmin_, ...).
    #
    def field_node(branch, key)

      node = branch.sublookup(key)
      node && node.result == 1 ? node : nil
    end

    # Walk the branch wrapper nodes in order.  The first failing
    # wrapper determines the field at stake; whether the token is fully
    # or only partially consumed distinguishes "missing" from
    # "out of range / invalid".
    #
    # Walk the branch wrapper nodes in order.  The first failing
    # wrapper determines the field at stake; whether the token is fully
    # or only partially consumed distinguishes "missing" from
    # "out of range / invalid".
    #
    def diagnose_branch(tree, bname, parsed)

      branch = branch_node(tree, bname)
      return unless branch

      itag = { interpretations: [ bname ] }
      @parsed_string = parsed

      consumed = 0
      good_tokens = 0
      fatal = nil

      branch.children.each do |wrapper|

        if wrapper.result == 1
          f = wrapper_field(wrapper)
          good_tokens += 1 if f
          consumed = wrapper.offset + wrapper.length
          next
        end

        # A trailing anonymous wrapper (the optional timezone alt).
        if wrapper_field(wrapper).nil? && wrapper.parter == :alt

          if parsed[wrapper.offset..-1].to_s.strip.empty?
            # Failing on empty input simply means no timezone given.
            break
          else
            # Text remains after the last field: a partial token the
            # field regex could not finish ("60" -> weekday "6" + "0").
            fatal = [ wrapper, consumed, good_tokens ]
            break
          end
        end

        fatal = [ wrapper, consumed, good_tokens ]
        break
      end

      if fatal
        fw, fconsumed, fgood = fatal
        diagnose_wrapper_failure(
          fw, bname, fconsumed, fgood, parsed,
          parsed[fconsumed..-1].to_s, itag, branch)
        return
      end

      # All wrappers matched, but the branch may have been marked a
      # failure for not consuming the whole input — typically the last
      # field greedily ate a prefix of a too-long token ("60" -> "6").
      if branch.result != 1 && branch.length < parsed.strip.length

        diagnose_partial_last_field(
          branch, consumed, good_tokens, parsed, itag)
        return
      end

      # Whole grammar matched: semantics only.
      diagnose_semantics(branch, consumed, itag)
    end

    # The last field consumed only a prefix of its token and characters
    # remain ("60" read as weekday "6"): report the whole token as
    # out of range / invalid.
    #
    def diagnose_partial_last_field(
      branch, consumed, good_tokens, parsed, itag)

      fields = branch_fields(branch.name)
      lastf = fields[[ good_tokens - 1, 0 ].max]
      info = FIELD_INFO[lastf]
      node = field_node(branch, lastf)

      rest = parsed[node.offset..-1].to_s
      tok = rest[/\S+/].to_s

      if (m = tok.match(/\A-?\d+/)) && m[0].length > node.length

        v = m[0].to_i
        if number_in_field_range?(lastf, v)
          add(:syntax, info[:field],
            node.offset, m[0].length,
            "invalid #{info[:name]} field #{m[0].inspect}",
            @mapping,
            { expected: field_expectation(lastf), got: m[0] }.merge(itag))
        else
          add(:out_of_range, info[:field],
            node.offset, m[0].length,
            "#{info[:name].capitalize} value #{v} is out of range, " +
            "expected #{info[:min]}..#{info[:max]}",
            @mapping,
            { expected: "#{info[:min]}..#{info[:max]}", got: v }.merge(itag))
        end
      else
        add(:syntax, info[:field],
          node.offset, [ tok.length, 1 ].max,
          "invalid #{info[:name]} field #{tok.inspect}",
          @mapping,
          { expected: field_expectation(lastf), got: tok }.merge(itag))
      end
    end

    def number_in_field_range?(key, v)

      case key
      when :hou then v.between?(0, 24)
      when :dom then v.between?(1, 31) || v.between?(-31, -1)
      when :dow then v.between?(0, 7)
      else
        info = FIELD_INFO[key]
        v.between?(info[:min], info[:max])
      end
    end

    # Given a failing wrapper and how much of the parsed string was
    # already consumed before it, emit one precise issue.
    #
    def diagnose_wrapper_failure(
      wrapper, bname, consumed, good_tokens, parsed, rest, itag, branch)

      field = wrapper_field(wrapper)
      stripped = rest.strip

      # A "tz" attempt wrapper is anonymous; detect timezone-shaped
      # suffix attempts.
      #
      if field.nil?

        if stripped =~ /[^\s&]/

          lead_ws = rest[0, rest.length - stripped.length].length
          attaches = lead_ws.zero?

          # The last field may have consumed a prefix of its token and
          # left the remainder here ("60" read as weekday "6").  Treat
          # the whole token as that field's out-of-range/invalid value.
          if attaches && (lastf = last_field_node(branch, wrapper))
            key, node = lastf
            if partially_consumed_token?(node, rest)
              diagnose_partial_token_field(key, node, itag)
              return
            end
          end

          # A suffix glued (no whitespace) to the last field token is a
          # syntax error in that field ("mon#6" -> #6 out of range,
          # "mon-foo" -> invalid weekday range).
          if attaches && (lastf = last_field_node(branch, wrapper))
            diagnose_field_suffix(lastf, consumed, stripped, itag)
            return
          end

          # Timezone-shaped trailing text.
          if timezone_failure?(wrapper, stripped)
            diagnose_tz_failure(consumed, rest, stripped, itag)
            return
          end

          add(:unexpected_input, nil,
            consumed + lead_ws, stripped.length,
            "unexpected input #{stripped.inspect} after the cron fields",
            @mapping, { got: stripped }.merge(itag))
        else
          et = deepest_failure(wrapper)
          add(:syntax, nil, et.offset, [ et.length, 1 ].max,
            'invalid cron syntax near here', @mapping, itag)
        end
        return
      end

      info = FIELD_INFO[field]

      lead_ws = rest[0, rest.length - stripped.length].length
      tok_pos = consumed + lead_ws

      missing = determine_missing(
        wrapper, bname, consumed, good_tokens, parsed, stripped, rest)

      if missing
        minfo = FIELD_INFO[missing]
        add(:missing_field, minfo[:field],
          [ consumed, parsed.length ].min, 0,
          "missing the #{minfo[:name]} field",
          @mapping,
          { expected: field_expectation(missing) }.merge(itag))
        return
      end

      # Did the wrapper consume a prefix of the token but not all of it?
      partial = partial_token(wrapper, consumed + lead_ws, stripped)

      if partial
        diagnose_partial_token(field, info, tok_pos, partial, itag)
      elsif (m = stripped.match(/\A-?\d+/)) &&
            number_token_in_range?(field, m[0].to_i)
        add(:syntax, info[:field], tok_pos, m[0].length,
          "invalid #{info[:name]} field #{m[0].inspect}",
          @mapping,
          { expected: field_expectation(field), got: m[0] }.merge(itag))
      elsif (m = stripped.match(/\A-?\d+/))
        v = m[0].to_i
        add(:out_of_range, info[:field], tok_pos, m[0].length,
          "#{info[:name].capitalize} value #{v} is out of range, " +
          "expected #{info[:min]}..#{info[:max]}",
          @mapping,
          { expected: "#{info[:min]}..#{info[:max]}", got: v }.merge(itag))
      else
        tok = stripped[/\S+/].to_s
        add(:syntax, info[:field], tok_pos, tok.length,
          "invalid #{info[:name]} field #{tok.inspect}",
          @mapping,
          { expected: field_expectation(field), got: tok }.merge(itag))
      end
    end

    # The field a wrapper stands for (from the named field-list node it
    # contains), or nil for the timezone/trailing wrapper.
    #
    def wrapper_field(wrapper)

      wrapper.children.each do |c|
        return c.name if c.name && FIELD_INFO.key?(c.name)
      end
      nil
    end

    FIELD_ORDER = %i[sec min hou dom mon dow].freeze

    def branch_fields(bname)

      bname == :scron ? FIELD_ORDER : FIELD_ORDER[1..-1]
    end

    # Decide whether a failing wrapper denotes a *missing* field.
    #
    # Two distinct situations look alike in the parse tree:
    #
    #  * "0 25 * * *" as a classic cron: the hour wrapper fails on the
    #    fresh token "25" — that is an out-of-range/invalid value, not
    #    a missing field.
    #
    #  * the same 5 fields as a second cron: the month wrapper fails at
    #    end-of-input after successfully re-reading the last token as a
    #    month — the day-of-week is genuinely missing.
    #
    def determine_missing(
      wrapper, bname, consumed, good_tokens, parsed, stripped, _rest)

      fields = branch_fields(bname)
      tokens = parsed.split(/[[:space:]]+/).reject(&:empty?)

      return fields[[ good_tokens, fields.size - 1 ].min] if stripped.empty?

      # Not enough whitespace-separated tokens to fill the required
      # fields, and the failing wrapper consumed one of the last tokens
      # (jseq/seq backtracking rewinds input but keeps its successful
      # children) rather than choking on a fresh token that is simply
      # invalid: the field at the token count is missing.
      #
      #   "0 25 * * *" as a second cron: 5 tokens for 6 fields
      #     -> month wrapper eats the 5th token, dow missing.
      #   "0 25 * * *" as a classic cron: the hour wrapper fails on the
      #     fresh 2nd token "25" -> out of range, not missing.
      #
      return nil unless tokens.size < fields.size

      consumed_field = wrapper
        .gather(nil)
        .find { |t| t.result == 1 && FIELD_INFO.key?(t.name) && t.length > 0 }

      ! consumed_field.nil? ? fields[tokens.size] : nil
    end

    # If the failing wrapper successfully consumed a prefix of the next
    # token ("25" -> "2", "60" -> "6"), return the consumed and full
    # token info.  nil otherwise.
    #
    def partial_token(wrapper, tok_pos, stripped)

      token = stripped[/\S+/].to_s
      return nil if token.empty?

      # Longest successfully consumed descendant leaf starting at the
      # token position.
      leaves = wrapper
        .gather(nil)
        .select { |t| t.result == 1 && t.children.empty? }

      consumed_len =
        leaves
          .select { |t| t.offset == tok_pos }
          .collect(&:length)
          .max

      return nil unless consumed_len
      return nil if consumed_len >= token.length
      return nil unless token[0, consumed_len] =~ /\A\d+\z/ ||
                        token[0, consumed_len] =~ /\A[A-Za-z]+\z/

      { full: token, consumed: consumed_len }
    end

    # A numeric token of which only a prefix was consumed (25 -> 2):
    # the whole number is out of range / invalid for the field.
    #
    def diagnose_partial_token(field, info, tok_pos, partial, itag)

      token = partial[:full]

      if (m = token.match(/\A-?\d+/))

        v = m[0].to_i
        if number_token_in_range?(field, v)
          add(:syntax, info[:field], tok_pos, token.length,
            "invalid #{info[:name]} field #{token.inspect}",
            @mapping,
            { expected: field_expectation(field), got: token }.merge(itag))
        else
          add(:out_of_range, info[:field], tok_pos, token.length,
            "#{info[:name].capitalize} value #{v} is out of range, " +
            "expected #{info[:min]}..#{info[:max]}",
            @mapping,
            { expected: "#{info[:min]}..#{info[:max]}", got: v }.merge(itag))
        end
      else
        # "monx" consumed "mon" prefix
        add(:syntax, info[:field], tok_pos, token.length,
          "invalid #{info[:name]} field #{token.inspect}",
          @mapping,
          { expected: field_expectation(field), got: token }.merge(itag))
      end
    end

    def number_token_in_range?(field, v)

      case field
      when :hou then v.between?(0, 24)
      when :dom then v.between?(1, 31) || v.between?(-31, -1)
      when :dow then v.between?(0, 7)
      else
        info = FIELD_INFO[field]
        v.between?(info[:min], info[:max])
      end
    end

    # Whether the remainder `rest` continues a numeric/word token that
    # the field node already started ("60": node ate "6", rest is "0").
    #
    def partially_consumed_token?(node, rest)

      return false if rest.empty?
      return false unless node.length > 0
      return false unless rest[0, 1] =~ /[0-9A-Za-z]/

      node.string =~ /[0-9A-Za-z]\z/
    end

    def diagnose_partial_token_field(key, node, itag)

      info = FIELD_INFO[key]

      # Rebuild the whole token: node string + contiguous continuation.
      full = node.string
      pos = node.offset
      src = @parsed_string || @core
      j = node.offset + node.length
      while j < src.length && src[j, 1] =~ /[0-9A-Za-z]/
        full << src[j, 1]
        j += 1
      end

      if (m = full.match(/\A-?\d+/))
        v = m[0].to_i
        if number_token_in_range?(key, v)
          add(:syntax, info[:field], pos, full.length,
            "invalid #{info[:name]} field #{full.inspect}",
            @mapping,
            { expected: field_expectation(key), got: full }.merge(itag))
        else
          add(:out_of_range, info[:field], pos, full.length,
            "#{info[:name].capitalize} value #{v} is out of range, " +
            "expected #{info[:min]}..#{info[:max]}",
            @mapping,
            { expected: "#{info[:min]}..#{info[:max]}", got: v }.merge(itag))
        end
      else
        add(:syntax, info[:field], pos, full.length,
          "invalid #{info[:name]} field #{full.inspect}",
          @mapping,
          { expected: field_expectation(key), got: full }.merge(itag))
      end
    end

    # The closest preceding successful field-list node relative to a
    # failing trailing wrapper.
    #
    def last_field_node(branch, failing_wrapper)

      siblings = branch.children
      idx = siblings.index(failing_wrapper)
      return nil unless idx

      siblings[0...idx].reverse_each do |w|
        next unless w.result == 1
        w.children.each do |c|
          return [ c.name, c ] if c.name && FIELD_INFO.key?(c.name)
        end
      end
      nil
    end

    # Report a suffix glued to the last field token ("mon#6",
    # "mon-foo") as a field-specific error rather than trailing junk.
    #
    def diagnose_field_suffix(field_pair, consumed, stripped, itag)

      key, _node = field_pair
      info = FIELD_INFO[key]

      if (m = stripped.match(/\A#([-\w]+)/))
        diagnose_hash_suffix(key, info, consumed, stripped, m, itag)
      elsif (m = stripped.match(/\A\/(\d+)/))
        v = m[1].to_i
        kind = v < 1 ? :out_of_range : :syntax
        add(kind, info[:field], consumed, m[0].length,
          "invalid step #{m[0].inspect} in #{info[:name]} field",
          @mapping, { got: m[0] }.merge(itag))
      else
        tok = stripped[/\S+/].to_s
        add(:syntax, info[:field], consumed, tok.length,
          "invalid #{info[:name]} field suffix #{tok.inspect}",
          @mapping,
          { expected: field_expectation(key), got: tok }.merge(itag))
      end
    end

    def diagnose_hash_suffix(key, info, consumed, stripped, m, itag)

      raw = m[1]
      v = raw.downcase[0, 1] == 'l' ? -1 :
        raw.match?(/\A-?\d+\z/) ? raw.to_i : nil

      if key == :dow && (v.nil? || v < -5 || v == 0 || v > 5)
        add(:out_of_range, :weekdays, consumed, m[0].length,
          "week occurrence ##{raw} is out of range",
          @mapping,
          { expected: '#-5, #L, or #1..#5', got: "##{raw}" }.merge(itag))
      else
        add(:syntax, info[:field], consumed, m[0].length,
          "invalid #{info[:name]} field suffix #{m[0].inspect}",
          @mapping, { got: m[0] }.merge(itag))
      end
    end

    def timezone_failure?(wrapper, stripped)

      stripped.match?(/\A([A-Z][A-Za-z0-9+\-_\/]+|[-+]\d)/)
    end

    def diagnose_tz_failure(consumed, rest, stripped, itag)

      if stripped.empty?
        add(:syntax, :timezone, consumed, 0,
          'incomplete timezone suffix', @mapping,
          { expected: tz_expectation }.merge(itag))
      else
        lead_ws = rest[0, rest.length - stripped.length].length
        tok = stripped[/\S+/].to_s
        add(:syntax, :timezone, consumed + lead_ws, tok.length,
          "invalid timezone #{tok.inspect}", @mapping,
          { expected: tz_expectation, got: tok }.merge(itag))
      end
    end

    # Fully-consumed branch: check semantics across the parsed fields.
    #
    def diagnose_semantics(branch, consumed, itag)

      tz_node = field_node(branch, :tz)

      if tz_node
        z = tz_node.strim
        if EtOrbi.get_tzone(z).nil?
          lead = tz_node.string[0, tz_node.string.length - z.length]
          add(:invalid_timezone, :timezone,
            tz_node.offset + lead.length, z.length,
            "invalid or unknown timezone #{z.inspect}",
            @mapping,
            { expected: tz_expectation, got: z }.merge(itag))
        end
      end

      elts = {}

      FIELD_INFO.each_key do |key|
        node = field_node(branch, key)
        next unless node
        check_field(key, node, itag)
        elts[key] = node
      end

      check_dom_mon_consistency(branch, elts, itag)
    end

    # Feb 30 (and friends): a day that exists in no selected month.
    #
    def check_dom_mon_consistency(branch, elts, itag)

      dom_node = elts[:dom]
      mon_node = elts[:mon]
      return unless dom_node

      begin
        doms = rewrite_entry_values(:dom, dom_node)
        mons = mon_node ? rewrite_entry_values(:mon, mon_node) : (1..12).to_a
      rescue StandardError
        return
      end

      bad = doms
        .select { |d| d.is_a?(Integer) && d > 0 }
        .select { |d| mons.none? { |m| d <= Fugit::Cron::MAXDAYS[m] } }

      bad.uniq.each do |d|

        ln = numeric_leaf(dom_node, d)
        add(:out_of_range, :monthdays,
          ln ? ln.offset : dom_node.offset,
          ln ? ln.length : dom_node.length,
          "day #{d} does not exist in the selected month(s)",
          @mapping,
          { expected: 'a day valid for at least one selected month',
            got: d }.merge(itag))
      end
    end

    def rewrite_entry_values(key, node)

      node.subgather(:elt).select { |e| e.result == 1 }.flat_map { |elt|
        a, z, = rewrite_elt(key, elt)
        [ a, z ]
      }.compact.uniq
    end

    def rewrite_elt(key, elt)

      Fugit::Cron::Parser.rewrite_elt(key, elt)
    end

    def check_field(key, node, itag)

      info = FIELD_INFO[key]

      node.subgather(:elt).select { |e| e.result == 1 }.each do |elt|

        st = elt.string

        begin
          a, z, _sep, sl, ha, _mo = rewrite_elt(key, elt)
        rescue StandardError
          next
        end

        if sl && sl < 1 && successful_slash?(elt)
          sn = elt.subgather(:slash).find { |s| s.result == 1 } || elt
          add(:out_of_range, info[:field],
            sn.offset, sn.length,
            "step #{sl} in #{st.inspect} is out of range, steps are 1+",
            @mapping,
            { expected: "a step of 1..#{info[:max]}", got: sl }.merge(itag))
        end

        if key == :dow && ha && successful_hash?(elt) &&
           (ha < -5 || ha == 0 || ha > 5)
          hn = elt.subgather(:hash).find { |h| h.result == 1 } || elt
          add(:out_of_range, :weekdays,
            hn.offset, hn.length,
            "week occurrence #{hn.strim.inspect} is out of range",
            @mapping,
            { expected: '#-5, #L, or #1..#5', got: hn.strim }.merge(itag))
        end

        if mixed_signs?(a, z)
          add(:syntax, info[:field],
            elt.offset, elt.length,
            "range bounds in #{st.inspect} must both be positive or " +
            'both be negative',
            @mapping,
            { expected: 'consistent signs for the range bounds',
              got: [ a, z ] }.merge(itag))
        end

        bounds =
          case key
          when :dow then [ [ a, 0, 7 ], [ z, 0, 7 ] ]
          when :hou then [ [ a, 0, 24 ], [ z, 0, 24 ] ]
          else [ [ a, info[:min], info[:max] ],
                 [ z, info[:min], info[:max] ] ]
          end

        bounds.each do |v, lo, hi|
          next if v.nil? || v.is_a?(String)
          next if v.between?(lo, hi)
          next if key == :dom && v.between?(-31, -1)

          ln = numeric_leaf(elt, v)
          add(:out_of_range, info[:field],
            ln ? ln.offset : elt.offset,
            ln ? ln.length : [ elt.length, 1 ].max,
            "#{info[:name].capitalize} value #{v} is out of range, " +
            "expected #{info[:min]}..#{info[:max]}",
            @mapping,
            { expected: "#{info[:min]}..#{info[:max]}", got: v }.merge(itag))
        end
      end
    end

    def successful_slash?(elt)

      elt.subgather(:slash).any? { |s| s.result == 1 && s.length > 0 }
    end

    def successful_hash?(elt)

      elt.subgather(:hash).any? { |h| h.result == 1 && h.length > 0 }
    end

    def mixed_signs?(a, z)

      a.is_a?(Integer) && z.is_a?(Integer) &&
        ((a < 0 && z > 0) || (z < 0 && a > 0))
    end

    def numeric_leaf(elt, v)

      s = v.to_s
      elt
        .gather(nil)
        .select { |t| t.children.empty? && t.result == 1 && t.string == s }
        .first
    end

    def tz_expectation

      'an IANA timezone name (like "America/New_York") ' +
      'or a UTC offset (like "+09:00")'
    end

    def field_expectation(key)

      case key
      when :sec, :min
        "#{FIELD_INFO[key][:min]}..#{FIELD_INFO[key][:max]}, \"*\" " +
        'or a range/list thereof'
      when :hou
        '0..23 (24 meaning 0), "*" or a range/list thereof'
      when :dom
        '1..31 (negative counts from the end of the month), "L" for ' +
        'last, "*" or a range/list thereof'
      when :mon
        '1..12, a month name, "*" or a range/list thereof'
      when :dow
        '0..7 (0 or 7 is Sunday), a weekday name, "*" or a ' +
        'range/list thereof'
      end
    end

    # First failing leaf (earliest offset) — fallback locator.
    #
    def deepest_failure(node)

      failed = node.children.select { |c| c.result != 1 }
      return node if failed.empty?

      deepest = failed.min_by { |c| c.offset } || failed.first
      deepest.children.empty? ? deepest : deepest_failure(deepest)
    end
  end

  # Duration diagnoser.
  #
  # A duration is either a plain form ("1h30m", "1y2d"), an ISO form
  # ("P1Y2D", "PT1H30M"), or a bare number (seconds).  Diagnosis
  # reports where parsing stopped, the offending unit/designator and
  # the expected syntax.
  #
  class DurationDiagnoser < Diagnoser

    FORMAT = :duration
    EMPTY_EXPECTED =
      'a duration like "1h30m", "P1D" or a number of seconds'

    def empty_input_valid?; true end
    private :empty_input_valid?

    PLAIN_UNIT =
      /(years?|months?|weeks?|days?|hours?|minutes?|seconds?|
        sec(ond)?s?|mins?|min(ute)?s?|[yMwdhms])/ix.freeze

    PLAIN_TOKEN =
      /([+-]?)(\d+\.\d*|(\d*\.)?\d+) *(#{PLAIN_UNIT.source})?/ix.freeze

    ISO_DATE_UNIT = 'YMWD'.freeze
    ISO_TIME_UNIT = 'HMS'.freeze

    protected

    def diagnose_core

      if (Fugit::Duration.parse(@s0, @opts) rescue nil)
        return
      end

      if @core.length > ::Fugit::MAX_INPUT_LENGTH
        add(:syntax, nil, 0, @core.length,
          "input too long for a duration, #{@core.length} " +
          "> #{::Fugit::MAX_INPUT_LENGTH} characters",
          nil, expected: "at most #{::Fugit::MAX_INPUT_LENGTH} characters")
        return
      end

      if @core.upcase.start_with?('P')
        diagnose_iso
      else
        diagnose_plain
      end
    end

    # Whether the text after a separator begins with a number that
    # carries a unit (so it is the next element of the duration).
    #
    def next_has_unit?(after)

      stripped = after.sub(/\A[[:space:],]*(and[[:space:]]+)?/i, '')

      !!(stripped =~ /\A[+-]?(?:\d+\.\d*|(?:\d*\.)?\d+) *#{PLAIN_UNIT}/i)
    end

    # Plain duration: [sign] number unit (sep number unit)*
    #
    def diagnose_plain

      pos = 0
      src = @core

      while pos < src.length

        pos += 1 while pos < src.length && src[pos, 1] =~ /[[:space:],]/
        break if pos >= src.length

        # Detect a stray dot inside what should be a number ("1.2.3h").
        if (dm = src[pos..-1].match(/\A\d+\.\d+(?=\.)/))
          add(:syntax, :duration,
            pos + dm[0].length, 1,
            "invalid number #{(src[pos..-1].split(/[^0-9.]/, 2).first)}",
            nil,
            expected: 'a number (optionally with one decimal point) ' +
                      'followed by a unit',
            got: '.')
          return
        end

        m = PLAIN_TOKEN.match(src, pos)
        break unless m && m.begin(0) == pos

        num = m[2]
        unit = m[4]

        if unit.nil?

          # A trailing bare number is seconds ("30", "1h30"), but a
          # number followed by a non-unit word is an error.
          after = src[m.end(0)..-1].to_s

          if after.strip.empty?
            # bare number at the end -> seconds, valid
            pos = m.end(0)
            next
          end

          lead = after[0, after.length - after.strip.length].length

          if lead > 0

            nxt = after.strip

            # "and" conjunction, or a following number that carries a
            # unit ("1h and 30m", "1h 2d"): keep scanning.  A following
            # number without a unit ("0 25") is an error here.
            if nxt =~ /\Aand\b/i || next_has_unit?(after)
              pos = m.end(0)
              next
            end

            # A separator followed by a bare number/word: the element
            # at the separator is incomplete.  Point at the next token.
            ntok = nxt[/\S+/].to_s
            add(:syntax, :duration,
              m.end(0) + lead, ntok.length,
              "invalid or missing time unit after #{num.inspect}",
              nil,
              expected: 'a unit: y (year), M (month), w (week), d ' +
                        '(day), h (hour), m (minute) or s (second)',
              got: ntok)
            return
          end

          # The number is glued to an invalid unit/char ("1z", "1分"):
          # highlight the offending unit-sized run.
          bad = after[/\A[[:alpha:]]*/]
          bad = after[0, 1] if bad.nil? || bad.empty?
          add(:syntax, :duration,
            m.end(0), bad.length,
            "invalid or missing time unit after #{num.inspect}",
            nil,
            expected: 'a unit: y (year), M (month), w (week), ' +
                      'd (day), h (hour), m (minute) or s (second)',
            got: bad)
          return
        end

        pos = m.end(0)
      end

      return if @report.issues.any?

      # Skip separators to reach the actual offending token.
      p0 = pos
      p0 += 1 while p0 < src.length && src[p0, 1] =~ /[[:space:],]/

      rest = src[p0..-1].to_s
      tok = rest[/\S+/].to_s

      if tok.empty?
        add(:syntax, :duration, pos, 0,
          'incomplete duration',
          nil, expected: 'a number followed by a unit (like "1h30m")')
      else
        add(:syntax, :duration, p0, tok.length,
          "invalid duration token #{tok.inspect}",
          nil,
          expected: 'a number followed by a unit (like "1h30m")',
          got: tok)
      end
    end

    # ISO 8601 duration: P [nY][nM][nW][nD] [T [nH][nM][nS]]
    #
    def diagnose_iso

      src = @core
      pos = 1 # skip P
      in_time = false

      while pos < src.length

        c = src[pos, 1]

        if c == 'T'
          in_time = true
          pos += 1
          next
        end

        m = /(-?\d+(?:\.\d+)?)([A-Za-z])?/.match(src, pos)

        if m.nil? || m.begin(0) != pos
          bad = src[pos..-1].to_s[/\S*/].to_s
          add(:syntax, :duration, pos, [ bad.length, 1 ].max,
            "invalid ISO 8601 duration near #{bad.inspect}",
            nil,
            expected: iso_expected(in_time),
            got: bad)
          return
        end

        num = m[1]
        unit = m[2]

        if unit.nil?
          add(:missing_field, :duration, m.end(1), 0,
            "missing the unit designator after #{num}",
            nil, expected: iso_expected(in_time))
          return
        end

        valid = in_time ? ISO_TIME_UNIT : ISO_DATE_UNIT
        unit_up = unit.upcase

        if ! valid.include?(unit_up) ||
           (in_time && unit_up == 'M' && unit !~ /[MS]/)
          # wrong-section designator (a time unit before T, ...)
          add(:syntax, :duration, m.begin(2), 1,
            "invalid ISO 8601 designator #{unit.inspect} " +
            (in_time ? 'in the time section (after T)' :
                       'in the date section (before T)'),
            nil,
            expected: iso_expected(in_time),
            got: unit)
          return
        end

        # Only seconds may carry a fractional value in ISO 8601.
        if num.include?('.') && unit_up != 'S'
          dpos = num.index('.')
          add(:out_of_range, :duration,
            m.begin(1) + dpos, num.length - dpos,
            "fractional value only allowed on seconds (S), " +
            "not on #{unit_up}",
            nil,
            expected: "an integer for #{unit_up} (or seconds with a " +
                      'decimal)',
            got: num)
          return
        end

        pos = m.end(0)
      end

      # Consumed everything but nothing after P/T: malformed.
      body = src[1..-1].delete('T')

      if body.empty?
        add(:missing_field, :duration, src.length, 0,
          "missing a duration component after #{src[-1] == 'T' ? 'T' : 'P'}",
          nil, expected: iso_expected(src[-1] == 'T'))
      end
    end

    def iso_expected(in_time)

      if in_time
        'a number followed by H (hour), M (minute) or S (second)'
      else
        'a number followed by Y (year), M (month), W (week) or ' +
        'D (day), optionally a T time section'
      end
    end
  end

  # Natural-language diagnoser ("every day at noon",
  # "every monday at 9", ...).
  #
  # The natural parser recognizes an English schedule phrase.  A
  # failure is either unparseable text, a consumed phrase with a
  # leftover the grammar cannot attach, or an out-of-range clock time
  # / unknown timezone.
  #
  class NatDiagnoser < Diagnoser

    FORMAT = :nat
    EMPTY_EXPECTED =
      'a schedule phrase like "every day at noon" or ' +
      '"every monday at 9"'

    DIGITAL_REX = /\b(\d{1,2}):(\d{2})\b/.freeze

    def empty_input_valid?; true end
    private :empty_input_valid?

    protected

    def diagnose_core

      single = (Fugit.parse_nat(@s0, @opts) rescue nil)

      if @core.length > ::Fugit::MAX_INPUT_LENGTH
        add(:syntax, nil, 0, @core.length,
          "input too long for a natural schedule, #{@core.length} " +
          "> #{::Fugit::MAX_INPUT_LENGTH} characters",
          nil, expected: "at most #{::Fugit::MAX_INPUT_LENGTH} characters")
        return
      end

      # Multiple distinct crons can be read from the same phrase
      # ("at 9:00 and 10:30"): even when the plain parser returns its
      # first cron, the meaning is ambiguous.  This is surfaced as an
      # informational ambiguity, not a hard parse failure.
      if ! @opts.key?(:multi) && (crons = multi_crons) && crons.size > 1
        crons.each { |c| @report.add_interpretation(c.to_cron_s) }
        @report.note_ambiguity(
          :nat, 0, @core.length,
          "ambiguous schedule phrase, it yields #{crons.size} distinct " +
          "crons: #{crons.collect(&:to_cron_s).inspect}",
          expected: 'a phrase that yields one cron (or pass multi: true)',
          got: crons.collect(&:to_cron_s))
      end

      return if single

      # A phrase the grammar fully consumes structurally may still
      # carry an unknown timezone slot.
      if (slots = parse_slots) && (bad = bad_timezone_slot(slots))
        z = bad.data0.first.to_s
        if (pos = locate_timezone(z))
          add(:invalid_timezone, :timezone,
            pos, z.length,
            "invalid or unknown timezone #{z.inspect}",
            nil, expected: 'an IANA timezone name (like "America/New_York")',
            got: z)
          return
        end
      end

      # Digital clock "HH:MM" with an out-of-range value.
      if (hit = find_digital_issue)
        add(:out_of_range, :nat, hit[:pos], hit[:len],
          hit[:message], nil,
          expected: 'an hour 0..24 and a minute 0..59 (as in "9:30")',
          got: hit[:got])
        return
      end

      tree =
        Fugit::Nat::Parser
          .parse(@core, prune: false, rewrite: false, all: false)

      if tree.result != 1

        add_nat_grammar_failure(tree)
        return
      end

      # Grammar consumed a prefix: locate the leftover text.
      diagnose_leftover(tree)
    end

    def parse_slots

      Fugit::Nat::Parser.parse(@core) rescue nil
    end

    def multi_crons

      r = Fugit.parse_nat(@core, @opts.merge(multi: true)) rescue nil
      r.is_a?(Array) ? r.uniq { |c| c.to_cron_s } : nil
    end

    def bad_timezone_slot(slots)

      tz = slots.instance_variable_get(:@slots)[:tz] rescue nil
      return nil unless tz

      z = Array(tz.data0).first.to_s
      EtOrbi.get_tzone(z).nil? ? tz : nil
    end

    def locate_timezone(z)

      @core.index(z)
    end

    # "at 25:00", "at 13:60" are structurally close to valid phrases;
    # surface the offending clock value explicitly.
    #
    def find_digital_issue

      m = DIGITAL_REX.match(@core)
      return nil unless m

      h = m[1].to_i
      min = m[2].to_i

      if h > 24
        { pos: m.begin(1), len: m[1].length, got: h,
          message: "hour value #{h} is out of range, expected 0..24" }
      elsif min > 59
        { pos: m.begin(2), len: m[2].length, got: min,
          message: "minute value #{min} is out of range, expected 0..59" }
      else
        nil
      end
    end

    def add_nat_grammar_failure(tree)

      consumed = tree.length
      rest = @core[consumed..-1].to_s

      # Find the earliest offset where the parser could not proceed.
      et = deepest_failure(tree)

      if rest.strip.empty?
        # Nothing consumed at all (e.g. "zzz", multibyte junk).
        pos = et.offset
        tok = @core[pos..-1].to_s[/\S+/].to_s
        len = tok.empty? ? 0 : tok.length
        add(:syntax, :nat, pos, len,
          "cannot understand #{tok.inspect} as a schedule phrase",
          nil,
          expected: 'a phrase starting with "every", "at", "on" or a ' +
                    'weekday/time (English)',
          got: tok)
      else
        diagnose_leftover(tree)
      end
    end

    # Text the grammar could not attach after a recognized prefix.
    #
    def diagnose_leftover(tree)

      consumed = tree.length
      rest = @core[consumed..-1].to_s
      lead = rest[0, rest.length - rest.strip.length].to_s
      stripped = rest.strip

      if stripped.empty?
        et = deepest_failure(tree)
        add(:syntax, :nat, et.offset, 0,
          'incomplete schedule phrase', nil,
          expected: 'a complete phrase like "every day at noon"')
        return
      end

      # A bare number left over ("every day 2024"): the grammar may
      # have consumed a prefix of the token ("20" of "2024"), but the
      # whole token is what the UI should highlight.
      stripped_tok = stripped[/\S+/].to_s
      tok_start_in_core = consumed + lead.length
      # walk back while the leftover continues an alphanumeric token
      while tok_start_in_core > 0 &&
            @core[tok_start_in_core - 1, 1] =~ /[A-Za-z0-9]/
        tok_start_in_core -= 1
      end
      # extend over the whole contiguous token
      tok_end = tok_start_in_core + stripped_tok.length
      while tok_end < @core.length && @core[tok_end, 1] =~ /[A-Za-z0-9]/
        tok_end += 1
      end
      pos = tok_start_in_core
      tok = @core[pos...tok_end]
      prefix = @core[0, pos].sub(/[[:space:]]+\z/, '')

      # If the leftover starts with a clock-like number, give a hint.
      if (m = stripped.match(/\A(\d{1,2}):(\d{2})/))
        add(:syntax, :nat, pos, m[0].length,
          "unexpected time #{m[0].inspect} here; prefix it with \"at\"",
          nil, expected: '"at HH:MM"', got: m[0])
      else
        add(:syntax, :nat, pos, tok.length,
          "unexpected text #{tok.inspect}" +
          (prefix.empty? ? '' : " after #{prefix.inspect}"),
          nil,
          expected: 'a schedule continuation (a time with "at", a ' +
                    'weekday with "on", ...) or the end of the phrase',
          got: tok)
      end
    end

    def deepest_failure(node)

      failed = node.children.select { |c| c.result != 1 }
      return node if failed.empty?

      deepest = failed.min_by(&:offset) || failed.first
      deepest.children.empty? ? deepest : deepest_failure(deepest)
    end
  end
end
