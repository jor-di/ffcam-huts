require_relative "test_helper"

# rb/py.rb: the formats of the data files (numbers, JSON, CSV, HTML entities)
class TestPy < Minitest::Test
  def test_float_repr
    [
      [0.0, "0.0"], [-0.0, "-0.0"],
    ].each { |f, s| assert_equal s, Py.float_repr(f) }
    {
      1.0 => "1.0", 0.1 => "0.1", 2.5 => "2.5", 0.30000000000000004 => "0.30000000000000004",
      1e15 => "1000000000000000.0", 9999999999999998.0 => "9999999999999998.0", 1e16 => "1e+16", 1.5e16 => "1.5e+16",
      123456789012345678.0 => "1.2345678901234568e+17", 1e22 => "1e+22", 1e100 => "1e+100",
      1e-4 => "0.0001", 0.000123 => "0.000123", 1e-5 => "1e-05", 1.5e-5 => "1.5e-05", -1e-7 => "-1e-07",
      5e-324 => "5e-324", 1.7976931348623157e308 => "1.7976931348623157e+308", 45.123456789 => "45.123456789",
      Float::INFINITY => "inf", -Float::INFINITY => "-inf", Float::NAN => "nan"
    }.each { |f, s| assert_equal s, Py.float_repr(f), f.inspect }
  end

  def test_round_to_int_is_half_even
    { 0.5 => 0, 1.5 => 2, 2.5 => 2, -2.5 => -2, -0.5 => 0, 3.7 => 4, 1234.4999 => 1234 }
      .each { |x, r| assert_equal r, Py.round(x), x.inspect }
    assert_kind_of Integer, Py.round(2.5)
  end

  def test_round_digits_uses_the_exact_binary_value
    # 2.675 is 2.67499999... in binary: 2.67 (Ruby's Float#round gives 2.68)
    { [2.675, 2] => 2.67, [1.005, 2] => 1.0, [0.125, 2] => 0.12, [0.375, 2] => 0.38, [45.1234565, 6] => 45.123457,
      [0.15, 1] => 0.1, [0.25, 1] => 0.2, [0.05, 1] => 0.1, [1234.5678, 1] => 1234.6, [6.0000005, 6] => 6.0 }
      .each { |(x, n), r| assert_equal r, Py.round(x, n), "round(#{x}, #{n})" }
    assert_equal "-0.0", Py.float_repr(Py.round(-0.0001, 2)) # sign of zero kept
    assert_equal(-0.1, Py.round(-0.05, 1))
    assert_equal 5, Py.round(5, 2) # an integer stays an integer
  end

  def test_dumps_compact_and_indented
    obj = { "b" => [1, 2.0, nil, true, false], "a" => {}, "c" => [], "d" => { "x" => "y" } }
    assert_equal '{"b": [1, 2.0, null, true, false], "a": {}, "c": [], "d": {"x": "y"}}', Py.dumps(obj)
    assert_equal '{"a":{},"b":[1,2.0,null,true,false],"c":[],"d":{"x":"y"}}', Py.dumps(obj, separators: [",", ":"], sort_keys: true)
    assert_equal "{\n \"b\": [\n  1,\n  2.0,\n  null,\n  true,\n  false\n ],\n \"a\": {},\n \"c\": [],\n \"d\": {\n  \"x\": \"y\"\n }\n}",
                 Py.dumps(obj, indent: 1)
    assert_equal "[\n  1e+16\n]", Py.dumps([1e16], indent: 2)
    assert_equal "[NaN, Infinity, -Infinity]", Py.dumps([Float::NAN, Float::INFINITY, -Float::INFINITY])
  end

  def test_dumps_strings
    line_sep = [0x2028].pack("U")
    s = "Refuge de l'Étendard \"q\" \\ \t\n\r\b\f \x01\x1f\x7f é😀#{line_sep}</"
    esc = ->(*hex) { hex.map { |h| "\\u#{h}" }.join } # esc["00e9"] is the 6 characters \ u 0 0 e 9
    ascii = %("Refuge de l'#{esc['00c9']}tendard \\"q\\" \\\\ \\t\\n\\r\\b\\f #{esc['0001', '001f', '007f']} ) +
            %(#{esc['00e9', 'd83d', 'de00', '2028']}</")
    utf8 = %("Refuge de l'Étendard \\"q\\" \\\\ \\t\\n\\r\\b\\f #{esc['0001', '001f']}\x7f é😀#{line_sep}</")
    assert_equal ascii, Py.dumps(s)
    assert_equal utf8, Py.dumps(s, ensure_ascii: false)
    assert_equal s, JSON.parse(Py.dumps(s))
  end

  def test_loads_and_raw_decode
    assert_equal({ "a" => [1, 2.5, nil] }, Py.loads('{"a": [1, 2.5, null]}'.b))
    text = 'xx"availability":{"s":"a}\"{","n":[{"x":1}]}, "after": {}'
    pos = text.index("{")
    assert_equal({ "s" => "a}\"{", "n" => [{ "x" => 1 }] }, Py.raw_decode(text, pos))
    assert_equal({ "é" => "à" }, Py.raw_decode('é é {"é":"à"} tail', 4)) # pos is a character index
    assert_raises(JSON::ParserError) { Py.raw_decode('{"open": [1, 2', 0) }
  end

  def test_csv_line
    assert_equal "a,b,1,2.5,True,False,,None\r\n", Py.csv_line(["a", "b", 1, 2.5, true, false, nil, "None"])
    assert_equal %("a,b","say ""hi""","l1\nl2","cr\r"\r\n), Py.csv_line(["a,b", 'say "hi"', "l1\nl2", "cr\r"])
    assert_equal "\"\"\r\n", Py.csv_line([""]) # a lone empty field is quoted
    assert_equal "\"\"\r\n", Py.csv_line([nil])
    assert_equal ",\r\n", Py.csv_line(["", nil])
    assert_equal " lead,trail ,é\r\n", Py.csv_line([" lead", "trail ", "é"])
  end

  def test_csv_round_trip
    rows = [
      { "name" => "Refuge de l'Aigle, \"Non Gardé\"", "note" => "line 1\nline 2\r\nline 3", "n" => "12", "empty" => "" },
      { "name" => "plain", "note" => "", "n" => "0", "empty" => "" },
      { "name" => ",", "note" => '"', "n" => '""', "empty" => "" },
    ]
    text = Py.csv_line(rows[0].keys) + rows.map { |r| Py.csv_line(r.values) }.join
    expected = rows.map { |r| r.merge("note" => r["note"].gsub("\r\n", "\n")) } # read in text mode: CRLF -> LF
    assert_equal expected, Py.csv_dicts(text)
  end

  def test_csv_dicts_edge_cases
    text = "a,b,c\r\n\r\nshort\r\n\"\",\"\"\r\nlone\"quote,\"ab\"cd,e\nlast,row,"
    assert_equal [{ "a" => "short", "b" => nil, "c" => nil }, { "a" => "", "b" => "", "c" => nil },
                  { "a" => "lone\"quote", "b" => "abcd", "c" => "e" }, { "a" => "last", "b" => "row", "c" => "" }],
                 Py.csv_dicts(text)
    assert_equal [], Py.csv_dicts("a,b\r\n")
  end

  def test_html_unescape
    {
      "a &amp; b" => "a & b", "&eacute;t&eacute;" => "été", "&#233;&#xE9;&#XE9" => "ééé", "&#x1F600;" => "😀",
      "&#0;" => "�", "&#xD800;" => "�", "&#x110000;" => "�", "&#128;" => "€", "&#129;" => "\u0081",
      "&#1;x" => "x", "&#127;" => "", "&#xFFFF;" => "", "&#13;" => "\r", "&nbsp" => " ", "&ampx" => "&x",
      "&notit;" => "¬it;", "&rsquo;&laquo;&raquo;&hellip;" => "’«»…", "&Eacute" => "É", "&unknown;" => "&unknown;",
      "no entity" => "no entity", "&" => "&", "&#;" => "&#;"
    }.each { |s, r| assert_equal r, Py.html_unescape(s), s }
  end

  def test_strip_truthy_either_float
    assert_equal "x y", Py.strip(" \t x y  \n")
    [nil, false, 0, 0.0, "", [], {}].each { |v| refute Py.truthy?(v), v.inspect }
    [true, 1, -0.5, "0", " ", [nil], { a: nil }].each { |v| assert Py.truthy?(v), v.inspect }
    assert_equal "x", Py.either("", "x")
    assert_equal 0.5, Py.float(" .5 ")
    assert_equal 1200.0, Py.float("1.2e3")
    assert_raises(ArgumentError) { Py.float("1.2.3") }
    assert_raises(TypeError) { Py.float(nil) }
  end

  def test_sorted_is_stable_and_urlencode
    items = [[2, "a"], [1, "b"], [2, "c"], [1, "d"]]
    assert_equal [[1, "b"], [1, "d"], [2, "a"], [2, "c"]], Py.sorted(items) { |i| i[0] }
    assert_equal "mode=FORM&q=a+b%2Cc%C3%A9~_.-&n=1", Py.urlencode({ "mode" => "FORM", "q" => "a b,cé~_.-", "n" => 1 })
  end

  def test_repr
    assert_equal %({'FFCAM': 3, "l'a": 0.0, 'x': [None, True]}), Py.repr({ "FFCAM" => 3, "l'a" => 0.0, "x" => [nil, true] })
  end
end
