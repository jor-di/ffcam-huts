require_relative "test_helper"

# Reading the booking sources: FFCAM calendar classes, Refuge Pro rules, Open System dates.
class TestSources < Minitest::Test
  # get_url returns `body` (no network) for the duration of the block
  def with_page(body)
    Couchette.singleton_class.alias_method(:real_get_url, :get_url)
    Couchette.define_singleton_method(:get_url) { |_url, *| body }
    yield
  ensure
    Couchette.singleton_class.alias_method(:get_url, :real_get_url)
    Couchette.singleton_class.remove_method(:real_get_url)
  end

  def test_ffcam_booking_classes
    html = <<~HTML
      <div class="day dispo"><a href="#" data-date="2026-11-20">20</a></div>
      <div class="day complet waitinglistday">
        <a class="x" data-date="2026-11-21">21</a></div>
      <div class="day completWeb completWebInfo"><a data-date="2026-11-22">22</a></div>
      <div class="day dispo completWeb"><a data-date="2026-11-23">23</a></div>
      <div class="day complet"><a data-date="2026-11-24">24</a></div>
      <div class="day disponible"><a data-date="2026-11-25">25</a></div>
      <div class="day	dispo"><a data-date="2026-11-27">tab</a></div>
    HTML
    # waiting list first, then phone (completWeb wins over dispo), then online; whole class names only
    assert_equal({ "2026-11-20" => "online", "2026-11-21" => "waitlist", "2026-11-22" => "phone",
                   "2026-11-23" => "phone", "2026-11-27" => "online" }, Couchette.booking_modes(html))
  end

  def test_js_var
    html = %(<script>\nBK.availability = {"2026-11-20": 3};\nBK.totalAvailability   =   {"2026-11-20": 30};  \nx = 1;\n</script>)
    assert_equal({ "2026-11-20" => 3 }, Couchette.js_var(html, "BK.availability"))
    assert_equal({ "2026-11-20" => 30 }, Couchette.js_var(html, "BK.totalAvailability"))
    assert_nil Couchette.js_var(html, "BK.openingCalendar")
  end

  DAYS = [
    { "date" => "2026-11-21", "status" => "open", "free" => 5, "capacity" => 10 },  # before today
    { "date" => "2026-11-22", "status" => "open", "free" => 5, "capacity" => 10 },  # today
    { "date" => "2026-11-23", "status" => "open", "free" => 5, "capacity" => 10 },
    { "date" => "2026-11-24", "status" => "open", "free" => 0, "capacity" => 10 },
    { "date" => "2026-11-25", "status" => "open", "free" => 3, "capacity" => 10, "isFull" => true },
    { "date" => "2026-11-26", "status" => "closed", "free" => 3, "capacity" => 10 },
    { "date" => "2026-12-20", "status" => "open", "free" => 7, "capacity" => 10 },
  ].freeze
  TODAY = Date.new(2026, 11, 22)

  def refugepro(info)
    with_page(refugepro_page(info)) { Couchette.fetch_refugepro_availability("x", TODAY) }
  end

  def test_refugepro_basic_rules
    out = refugepro("data" => DAYS)
    assert_equal({ "2026-11-21" => "phone", "2026-11-22" => "online", "2026-11-23" => "online", "2026-11-24" => nil,
                   "2026-11-25" => nil, "2026-12-20" => "online" }, out["booking"]) # closed day: no booking mode
    assert_equal "CLOSE", out["opening"]["2026-11-26"]
    assert_equal 0, out["free"]["2026-11-21"] # past cutoff: no longer sold online
    assert_equal 3, out["free"]["2026-11-25"] # full: free beds kept as given
    assert_equal 10, out["capacity"]["2026-11-21"]
  end

  def test_refugepro_cutoff_and_waitlist
    out = refugepro("data" => DAYS, "bookingCutoffDays" => 2, "waitlistEnabled" => true)
    assert_equal %w[phone phone phone waitlist waitlist online],
                 out["booking"].values_at("2026-11-21", "2026-11-22", "2026-11-23", "2026-11-24", "2026-11-25", "2026-12-20")
    assert_equal [0, 0, 0], out["free"].values_at("2026-11-21", "2026-11-22", "2026-11-23")
  end

  def test_refugepro_next_season_opening
    not_yet = refugepro("data" => DAYS, "nextSeasonOpening" => { "ouvreLe" => "2026-12-01", "premiereNuit" => "2026-12-20" })
    assert_equal "phone", not_yet["booking"]["2026-12-20"] # online sales not open yet for the season
    assert_equal 0, not_yet["free"]["2026-12-20"]
    assert_equal "online", not_yet["booking"]["2026-11-23"] # before the first night of the season
    opened = refugepro("data" => DAYS, "nextSeasonOpening" => { "ouvreLe" => "2026-11-22", "premiereNuit" => "2026-12-20" })
    assert_equal "online", opened["booking"]["2026-12-20"] # sales open from today on
    no_first_night = refugepro("data" => DAYS, "nextSeasonOpening" => { "ouvreLe" => "2026-12-01" })
    assert_equal "online", no_first_night["booking"]["2026-12-20"]
    nulls = refugepro("data" => DAYS, "nextSeasonOpening" => nil, "bookingCutoffDays" => nil)
    assert_equal "online", nulls["booking"]["2026-11-22"]
  end

  def test_refugepro_unguarded_days
    days = [{ "date" => "2026-11-23", "capacity" => 12, "free" => 12, "status" => "open", "isFull" => false, "unguarded" => true },
            { "date" => "2026-11-24", "capacity" => 12, "free" => 12, "status" => "closed", "unguarded" => true }]
    out = refugepro("data" => days)
    assert_equal({ "2026-11-23" => "UNGUARDED", "2026-11-24" => "CLOSE" }, out["opening"])
    assert_equal "online", out["booking"]["2026-11-23"] # still booked online, places kept
    assert_equal 12, out["free"]["2026-11-23"]
  end

  def test_refugepro_without_data
    assert_equal({ "free" => {}, "capacity" => {}, "opening" => {}, "booking" => {} }, refugepro({}))
    error = assert_raises(RuntimeError) { with_page("<html></html>") { Couchette.fetch_refugepro_availability("galibier", TODAY) } }
    assert_equal "no availability in the Refuge Pro calendar of galibier", error.message
  end

  def test_opensystem_date_mapping
    # the answer covers query - 15 .. query + 14, with query = date + 15; day = query - d
    body = 'cb([{"planning":[{"s":3,"f":0,"d":15},{"s":0,"f":1,"d":0},{"s":2,"f":0,"d":-14}]}])'
    out = with_page(body) { Couchette.fetch_opensystem_availability("OPRF-92948", Date.new(2026, 12, 20)) }
    assert_equal({ "2026-12-20" => 3, "2027-01-04" => 0, "2027-01-18" => 2 }, out["free"])
    assert_equal({ "2026-12-20" => "OPEN", "2027-01-04" => "CLOSE", "2027-01-18" => "OPEN" }, out["opening"])
    assert_equal [nil, nil, nil], out["capacity"].values
    # month and year ends, leap day
    out = with_page('cb([{"planning":[{"s":1,"f":0,"d":15},{"s":1,"f":0,"d":1}]}])') do
      Couchette.fetch_opensystem_availability("OPRF-1", Date.new(2028, 2, 15))
    end
    assert_equal %w[2028-02-15 2028-02-29], out["free"].keys
  end

  def test_opensystem_guarded_season
    # 2026-05-31 open (outside the season), 06-01 and 09-30 open (in it), 10-01 open but full, 10-02 closed
    body = 'cb([{"planning":[{"s":4,"f":0,"d":15},{"s":4,"f":0,"d":14},{"s":4,"f":0,"d":-107},{"s":0,"f":0,"d":-108},{"s":0,"f":1,"d":-109}]}])'
    out = with_page(body) { Couchette.fetch_opensystem_availability("OPRF-1", Date.new(2026, 5, 31), [%w[06-01 09-30]]) }
    assert_equal({ "2026-05-31" => "UNGUARDED", "2026-06-01" => "OPEN", "2026-09-30" => "OPEN", "2026-10-01" => "OPEN", "2026-10-02" => "CLOSE" },
                 out["opening"])
    assert_equal({ "2026-05-31" => "online" }, out["booking"])
    # no season: every open night is guarded
    out = with_page(body) { Couchette.fetch_opensystem_availability("OPRF-1", Date.new(2026, 5, 31)) }
    assert_equal ["OPEN"], out["opening"].values.uniq - ["CLOSE"]
    assert_empty out["booking"]
  end

  def test_guarded_on
    seasons = [%w[03-21 05-10], %w[06-06 09-06]]
    assert Couchette.guarded_on?(seasons, "2027-03-21")
    assert Couchette.guarded_on?(seasons, "2027-09-06")
    refute Couchette.guarded_on?(seasons, "2027-05-20")
    refute Couchette.guarded_on?(seasons, "2026-11-27")
    winter = [%w[12-12 03-28]] # over the new year
    assert Couchette.guarded_on?(winter, "2026-12-12")
    assert Couchette.guarded_on?(winter, "2027-01-15")
    assert Couchette.guarded_on?(winter, "2027-03-28")
    refute Couchette.guarded_on?(winter, "2026-12-11")
    refute Couchette.guarded_on?(winter, "2027-07-01")
  end

  def test_opensystem_empty_and_broken_answers
    empty = { "free" => {}, "capacity" => {}, "opening" => {}, "booking" => {} }
    %w[cb([]) cb(null) cb([{"planning":[]}])].each do |body|
      assert_equal empty, with_page(body) { Couchette.fetch_opensystem_availability("OPRF-1", TODAY) }, body
    end
    error = assert_raises(RuntimeError) { with_page("<html>maintenance</html>") { Couchette.fetch_opensystem_availability("OPRF-1", TODAY) } }
    assert_match(/no JSONP payload/, error.message)
  end

  def test_fetch_availability_dispatch
    assert_nil Couchette.fetch_availability("M-1", TODAY, "MANUAL")
  end

  def test_norm_and_email_user
    assert_equal "gouter", Couchette.norm("Refuge du Goûter")
    assert_equal Couchette.norm("Refuge de l'Aigle"), Couchette.norm("Refuge de l'Aigle (Non Gardé)")
    assert_equal "evettes", Couchette.norm("Chalet-Refuge CAF des Évettes")
    assert_equal "lacnoir", Couchette.norm("Refuge du Lac Noir non gardé")
    assert_equal "refuge.aigle", Couchette.email_user("refuge<d></d>aigle<a></a><ff></ff><d></d><fr></fr>")
    assert_nil Couchette.email_user(nil)
    assert_nil Couchette.email_user("<a></a>x")
  end
end
