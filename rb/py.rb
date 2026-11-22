# Output formats of the data files, kept byte for byte.
#
# The project was first written in Python. Its files are still read and diffed as text: the
# availability history and fetch log on the `data` branch (history/: availability_*.csv,
# state.json, fetch_log.json, one git commit per run), and huts.json, hut_coordinates.json,
# hut_links.json in the repository. Writing them exactly as before (same number formatting,
# JSON spacing and escapes, CSV quoting, rounding) keeps git diffs limited to real changes
# and lets tests/check.sh compare outputs byte for byte with tests/golden/. Ruby's own
# JSON / CSV / Float#to_s / Float#round differ in small ways (1.0e+16 vs 1e+16, rounding of
# halfway cases, escapes...), hence these helpers, named after the Python functions whose
# output they reproduce (dumps, round, repr...). The module name is kept for that reason.

require "json"
require "strscan"

module Py
  module_function

  # "Truthy" as the data rules were written: nil, false, 0, 0.0, "" and empty arrays / hashes
  # count as missing (a hut with free: 0 is not bookable, "" means no value in a CSV).
  def truthy?(value)
    case value
    when nil, false then false
    when Numeric then !value.zero?
    when String, Array, Hash then !value.empty?
    else true
    end
  end

  # `a or b`
  def either(value, fallback)
    truthy?(value) ? value : fallback
  end

  # A float as written in the data files: shortest round-trip digits (like Float#to_s), but
  # 1e+16 / 1e-05 / 1000000000000000.0 where Ruby writes 1.0e+16 / 1.0e-05 / 1.0e+15.
  def float_repr(f)
    return "nan" if f.nan?
    return f.positive? ? "inf" : "-inf" if f.infinite?
    s = f.to_s
    return s unless s.include?("e") # fixed notation: same digits
    mantissa, exp = s.split("e")
    sign = mantissa.start_with?("-") ? "-" : ""
    int, frac = mantissa.delete("-").split(".")
    digits = (int + frac).sub(/0+\z/, "")
    decpt = exp.to_i + int.size # position of the decimal point in digits
    if decpt > -4 && decpt <= 16
      fixed = if decpt <= 0 then "0.#{'0' * -decpt}#{digits}"
              elsif decpt >= digits.size then "#{digits}#{'0' * (decpt - digits.size)}.0"
              else "#{digits[0, decpt]}.#{digits[decpt..]}"
              end
      sign + fixed
    else
      mant = digits.size > 1 ? "#{digits[0]}.#{digits[1..]}" : digits
      format("%s%se%s%02d", sign, mant, decpt - 1 >= 0 ? "+" : "-", (decpt - 1).abs)
    end
  end

  # A value as written in CSV cells and messages (nil -> None, true -> True, floats as above)
  def str(value)
    case value
    when nil then "None"
    when true then "True"
    when false then "False"
    when Float then float_repr(value)
    else value.to_s
    end
  end

  # round(x) -> int, round(x, n) -> float: correctly rounded, ties to even
  # (Ruby's Float#round(n) rounds x * 10**n, which can differ on halfway cases).
  def round(x, digits = nil)
    return x.to_r.round(half: :even) if digits.nil?
    return x if x.is_a?(Integer)
    # exact decimal result, then the nearest float (Rational#to_f is not always correctly rounded)
    units = (x.to_r * 10**digits).round(half: :even)
    rounded = Float("#{units.negative? ? '-' : ''}#{units.abs}e-#{digits}")
    return rounded unless rounded.zero?
    x.negative? || (x.zero? && (1.0 / x).negative?) ? -0.0 : 0.0 # keep the sign of zero (-0.0)
  end

  # A float from a string or a number; ArgumentError for a malformed string, TypeError otherwise
  def float(value)
    return value.to_f if value.is_a?(Numeric)
    raise TypeError, "float() argument must be a string or a real number" unless value.is_a?(String)
    s = value.strip
    return Float::NAN if s.match?(/\A[+-]?nan\z/i)
    return s.start_with?("-") ? -Float::INFINITY : Float::INFINITY if s.match?(/\A[+-]?inf(inity)?\z/i)
    raise ArgumentError, "could not convert string to float: #{value.inspect}" unless
      s.match?(/\A[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?\z/)
    s.to_f
  end

  # String#strip that also removes Unicode spaces (no-break space...), common in scraped names
  SPACE = "[\\s\\u001c-\\u001f\\u0085\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000]"
  STRIP = /\A#{SPACE}+|#{SPACE}+\z/
  def strip(s)
    s.gsub(STRIP, "")
  end

  # Stable sort: equal keys keep their input order (Ruby's sort_by is not stable).
  def sorted(items, &key)
    items.each_with_index.sort_by { |item, i| [*key.call(item), i] }.map(&:first)
  end

  # ---------- JSON ----------
  JSON_ESCAPES = { '"' => '\\"', "\\" => "\\\\", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t",
                   "\b" => "\\b", "\f" => "\\f" }.freeze

  # JSON text: ", " / ": " separators (or `separators`), `indent` spaces per level with one item
  # per line, non-ASCII as \uXXXX unless ensure_ascii: false, keys in insertion order unless
  # sort_keys; floats as float_repr.
  def dumps(obj, indent: nil, separators: nil, ensure_ascii: true, sort_keys: false)
    item_sep, key_sep = separators || (indent ? [",", ": "] : [", ", ": "])
    opts = { indent: indent, item_sep: item_sep, key_sep: key_sep, ascii: ensure_ascii, sort: sort_keys }
    encode(obj, opts, 0)
  end

  def encode(obj, opts, level)
    case obj
    when Hash
      return "{}" if obj.empty?
      pairs = opts[:sort] ? obj.sort_by { |k, _| k.to_s } : obj
      container("{", "}", pairs.map { |k, v| json_string(k.to_s, opts[:ascii]) + opts[:key_sep] + encode(v, opts, level + 1) }, opts, level)
    when Array
      return "[]" if obj.empty?
      container("[", "]", obj.map { |v| encode(v, opts, level + 1) }, opts, level)
    when String then json_string(obj, opts[:ascii])
    when nil then "null"
    when true then "true"
    when false then "false"
    when Float
      return "NaN" if obj.nan?
      return obj.positive? ? "Infinity" : "-Infinity" if obj.infinite?
      float_repr(obj)
    when Integer then obj.to_s
    else json_string(obj.to_s, opts[:ascii])
    end
  end

  def container(open, close, items, opts, level)
    return open + items.join(opts[:item_sep]) + close unless opts[:indent]
    inner = "\n" + " " * (opts[:indent] * (level + 1))
    open + inner + items.join(opts[:item_sep] + inner) + "\n" + " " * (opts[:indent] * level) + close
  end

  def json_string(s, ascii)
    pattern = ascii ? /[^\x20-\x7e]|[\\"]/ : /[\x00-\x1f\\"]/ # ensure_ascii: printable ASCII only (DEL escaped too)
    escaped = s.gsub(pattern) do |c|
      JSON_ESCAPES[c] || c.encode("UTF-16BE").unpack("n*").map { |u| format("\\u%04x", u) }.join
    end
    "\"#{escaped}\""
  end

  # Parse JSON (bytes are UTF-8)
  def loads(text)
    JSON.parse(text.dup.force_encoding(Encoding::UTF_8), allow_nan: true)
  end

  # Parse the JSON object or array starting at pos (a character index) in a longer text, ignoring
  # what follows: finds its end, skipping strings, then parses that slice.
  def raw_decode(text, pos)
    s = StringScanner.new(text)
    s.pos = text[0, pos].bytesize
    start, depth = s.pos, 0
    loop do
      if s.skip(/"(?:[^"\\]++|\\.)*+"/) || s.skip(/[^"{}\[\]]+/)
        next
      elsif s.skip(/[{\[]/)
        depth += 1
      elsif s.skip(/[}\]]/)
        depth -= 1
        break if depth.zero?
      else
        raise JSON::ParserError, "unterminated JSON value at #{pos}"
      end
    end
    loads(text.byteslice(start...s.pos))
  end

  # ---------- CSV ----------
  # A CSV row: fields quoted only when they contain , " CR or LF, "\r\n" line ending.
  def csv_line(values)
    return "\"\"\r\n" if values.size == 1 && (values[0].nil? || values[0] == "") # a lone empty field is quoted
    values.map do |v|
      s = v.nil? ? "" : str(v)
      s.match?(/[",\r\n]/) ? "\"#{s.gsub('"', '""')}\"" : s
    end.join(",") + "\r\n"
  end

  # Rows of a CSV text as [{header => value}]: line endings normalized to "\n" (also inside
  # quoted fields), blank lines skipped, missing trailing fields nil.
  def csv_dicts(text)
    s = StringScanner.new(text.gsub(/\r\n?/, "\n"))
    rows, row = [], []
    until s.eos?
      quoted = s.scan(/"((?:[^"]|"")*)"/)
      field = quoted ? s[1].gsub('""', '"') + s.scan(/[^,\n]*/) : s.scan(/[^,\n]*/)
      row << field
      next if s.skip(/,/)
      s.skip(/\n/)
      rows << row unless row == [""] && !quoted # blank line
      row = []
    end
    rows << row + [""] unless row.empty? # text ending with a comma
    header, *data = rows
    data.map { |r| header.each_with_index.to_h { |h, i| [h, r[i]] } }
  end

  # ---------- misc ----------
  # {'FFCAM': 3} notation of the hashes printed in the summary lines on stderr
  def repr(value)
    case value
    when Hash then "{" + value.map { |k, v| "#{repr(k)}: #{repr(v)}" }.join(", ") + "}"
    when Array then "[" + value.map { |v| repr(v) }.join(", ") + "]"
    when String
      return "\"#{value}\"" if value.include?("'") && !value.include?('"')
      "'#{value.gsub('\\') { '\\\\' }.gsub("'") { "\\'" }}'"
    else str(value)
    end
  end

  # Form encoding (a+b%C3%A9): everything but letters, digits and "_.-~" is %-encoded, space is +.
  # The query strings must not change: they identify the recorded requests of tests/fixtures/.
  def quote_plus(value)
    str(value).b.gsub(/[^A-Za-z0-9_.\-~ ]/n) { |c| format("%%%02X", c.ord) }.tr(" ", "+").force_encoding(Encoding::UTF_8)
  end

  def urlencode(params)
    params.map { |k, v| "#{quote_plus(k)}=#{quote_plus(v)}" }.join("&")
  end

  # Decode HTML character references in scraped names: numeric references and the HTML 4
  # named entities (not all of HTML 5's: the sources only use a handful).
  LATIN1 = %w[nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr deg plusmn
              sup2 sup3 acute micro para middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest Agrave
              Aacute Acirc Atilde Auml Aring AElig Ccedil Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml
              ETH Ntilde Ograve Oacute Ocirc Otilde Ouml times Oslash Ugrave Uacute Ucirc Uuml Yacute THORN
              szlig agrave aacute acirc atilde auml aring aelig ccedil egrave eacute ecirc euml igrave iacute
              icirc iuml eth ntilde ograve oacute ocirc otilde ouml divide oslash ugrave uacute ucirc uuml
              yacute thorn yuml]
  ENTITIES = LATIN1.each_with_index.to_h { |n, i| [n, (160 + i).chr(Encoding::UTF_8)] }.merge(
    "amp" => "&", "lt" => "<", "gt" => ">", "quot" => '"', "apos" => "'", "OElig" => "Œ", "oelig" => "œ",
    "euro" => "€", "ndash" => "–", "mdash" => "—", "lsquo" => "‘", "rsquo" => "’", "sbquo" => "‚",
    "ldquo" => "“", "rdquo" => "”", "bdquo" => "„", "hellip" => "…", "bull" => "•", "laquo" => "«",
    "raquo" => "»", "trade" => "™", "thinsp" => " ", "ensp" => " ", "emsp" => " "
  ).freeze

  # names also recognized without the final ";" (HTML legacy)
  LEGACY = (LATIN1 + %w[amp lt gt quot]).to_h { |n| [n, ENTITIES[n]] }
                                       .merge("AMP" => "&", "LT" => "<", "GT" => ">", "QUOT" => '"', "COPY" => "©", "REG" => "®").freeze

  # code points a numeric reference never gives (dropped); 0x80-0x9F are read as Windows-1252
  NO_CHARACTER = [0x1..0x8, 0xB..0xB, 0xE..0x1F, 0x7F..0x7F, 0xFDD0..0xFDEF].freeze

  def html_unescape(s)
    return s unless s.include?("&")
    s.gsub(/&(#[0-9]+;?|#[xX][0-9a-fA-F]+;?|[^\t\n\f <&#;]{1,32};?)/) do |ref|
      body = ref[1..]
      next named_entity(body) unless body.start_with?("#")
      body = body.chomp(";")
      n = body[1].casecmp?("x") ? body[2..].to_i(16) : body[1..].to_i
      if n.zero? || (0xD800..0xDFFF).cover?(n) || n > 0x10FFFF then "\uFFFD"
      elsif NO_CHARACTER.any? { |r| r.cover?(n) } || (n & 0xFFFE) == 0xFFFE then "" # control or non-character
      elsif (0x80..0x9F).cover?(n) then n.chr.force_encoding("Windows-1252").encode("UTF-8", undef: :replace, replace: n.chr(Encoding::UTF_8))
      else n.chr(Encoding::UTF_8)
      end
    end
  end

  # "name;" or "name": the entity, else the longest legacy name it starts with, else unchanged
  def named_entity(body)
    return ENTITIES[body.chomp(";")] if body.end_with?(";") && ENTITIES.key?(body.chomp(";"))
    return LEGACY[body] if LEGACY.key?(body)
    (body.size - 1).downto(2) do |x|
      return LEGACY[body[0, x]] + body[x..] if LEGACY.key?(body[0, x])
    end
    "&#{body}"
  end
end
