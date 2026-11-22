require_relative "test_helper"

# WP Booking System calendars (portal WPBS, Refuge de la Coire): Ffcam.parse_wpbs and
# Ffcam.fetch_wpbs_availability, on a trimmed copy of the real page (fixtures/wpbs_calendar.html).
class TestWpbs < Minitest::Test
  PAGE = File.read(File.join(__dir__, "fixtures", "wpbs_calendar.html"), encoding: "UTF-8")
  URL = "https://www.refugedelacoire.fr/reservations-hiver/"
  TODAY = Date.new(2026, 12, 27)

  # get_url serves `pages` ({url => body}, no network) for the duration of the block
  def with_pages(pages)
    Ffcam.singleton_class.alias_method(:real_get_url, :get_url)
    Ffcam.define_singleton_method(:get_url) { |url, *| pages.fetch(url) }
    yield
  ensure
    Ffcam.singleton_class.alias_method(:get_url, :real_get_url)
    Ffcam.singleton_class.remove_method(:real_get_url)
  end

  def parse(html = PAGE, today = TODAY, **opts)
    Ffcam.parse_wpbs(html, URL, today, **opts)
  end

  # [opening, free, booking] per day
  def rows(out)
    out["opening"].keys.to_h { |d| [d, [out["opening"][d], out["free"][d], out["booking"][d]]] }
  end

  def test_statuses_inventory_and_month_boundary
    out = parse
    assert_equal({
      "2026-12-27" => ["OPEN", 1, "online"],    # today, "1 pl."
      "2026-12-28" => ["OPEN", nil, "request"], # bookable, no inventory shown: places unknown
      "2026-12-29" => ["OPEN", 0, nil],         # "Complet", not bookable
      "2026-12-30" => ["OPEN", 0, nil],         # inventory "Complet" (wpbs-full)
      "2026-12-31" => ["OPEN", 0, nil],         # "0 pl."
      "2027-01-01" => ["CLOSE", nil, nil],      # "Non-disponible"
      "2027-01-02" => ["CLOSE", nil, nil],      # "Voir refuge été" (HTML entities), even bookable with places
      "2027-01-03" => ["OPEN", 0, nil],         # changeover start (not in the legend): the night is taken
      "2027-01-04" => ["OPEN", 3, "online"],    # changeover end, bookable: available
      "2027-01-05" => ["CLOSE", nil, nil],      # available status but not bookable
      "2027-01-06" => ["OPEN", 5, "online"],    # changeover start but bookable with places: the inventory wins
      "2027-01-07" => ["OPEN", 12, "online"],
    }, rows(out))
    assert_equal [nil], out["capacity"].values.uniq # no capacity given
    assert_equal out["opening"].keys, out["capacity"].keys
  end

  def test_past_days_skipped
    assert_equal "2026-12-27", parse["opening"].keys.min # 13-15 and 26 December are over
    later = parse(PAGE, Date.new(2027, 1, 4))
    assert_equal %w[2027-01-04 2027-01-05 2027-01-06 2027-01-07], later["opening"].keys
    # a calendar whose days are all over: an empty answer (the fetch log shows "Réponse vide"), not an error
    assert_equal({}, parse(PAGE, Date.new(2027, 2, 1))["opening"])
  end

  def test_legend_meanings
    assert_equal :available, Ffcam.wpbs_meaning("Disponible (selon conditions)")
    assert_equal :available, Ffcam.wpbs_meaning("Disponible (non-gardé)")
    assert_equal :full, Ffcam.wpbs_meaning("Complet")
    assert_equal :closed, Ffcam.wpbs_meaning("Non-disponible")
    assert_equal :closed, Ffcam.wpbs_meaning("Voir refuge été")
    assert_equal :closed, Ffcam.wpbs_meaning("Fermé")
    assert_nil Ffcam.wpbs_meaning("Tarif spécial")
  end

  def test_several_calendars_and_pages
    second = PAGE.sub('data-id="12"', 'data-id="14"').gsub("<span class=\"wpbs-inventory\">1 pl.</span>", "<span class=\"wpbs-inventory\">7 pl.</span>")
    both = PAGE + second
    assert_equal 1, parse(both)["free"]["2026-12-27"] # a day of several calendars: the first one
    assert_equal 7, parse(both, calendars: [14])["free"]["2026-12-27"]
    assert_equal 7, parse(both, calendars: ["14"])["free"]["2026-12-27"]
    pages = { URL => PAGE, "https://x/ete/" => second }
    with_pages(pages) do
      out = Ffcam.fetch_wpbs_availability([{ "url" => "https://x/ete/" }, URL], TODAY)
      assert_equal [7, nil, "online"], [out["free"]["2026-12-27"], out["capacity"]["2026-12-27"], out["booking"]["2026-12-27"]]
      assert_equal 12, out["opening"].size
      assert_equal rows(parse), rows(Ffcam.fetch_wpbs_availability([{ "url" => URL }], TODAY))
    end
  end

  def test_dispatch
    with_pages(URL => PAGE) do
      out = Ffcam.fetch_availability("WPBS-coire", TODAY, "WPBS", [{ "url" => URL }])
      assert_equal %w[free capacity opening booking], out.keys
      # without a date: today on the real clock
      assert_equal rows(parse(PAGE, Ffcam.local_today)), rows(out)
    end
  end

  def test_errors
    error = assert_raises(RuntimeError) { parse("<html><body>Maintenance</body></html>") }
    assert_equal "no WP Booking System calendar on #{URL}", error.message
    no_days = PAGE.gsub(/data-(year|month|day)="\d+"/, "")
    error = assert_raises(RuntimeError) { parse(no_days) }
    assert_equal "no day in the WP Booking System calendar of #{URL}", error.message
    # CSS mentioning the class is not a calendar
    assert_raises(RuntimeError) { parse("<style>.wpbs-container .wpbs-legend {}</style>") }
  end

  def test_manual_portal
    assert_equal "REFUGEPRO", Ffcam.manual_portal("refugepro" => "galibier")
    assert_equal "WPBS", Ffcam.manual_portal("wpbs" => [{ "url" => URL }])
    assert_equal "MANUAL", Ffcam.manual_portal("wpbs" => [])
    assert_equal "MANUAL", Ffcam.manual_portal({})
  end
end
