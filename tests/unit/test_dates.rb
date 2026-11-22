require_relative "test_helper"

# weekend_nights / next_weekend_nights (rb/ffcam_availability.rb)
class TestDates < Minitest::Test
  D = ->(s) { Date.iso8601(s) }

  # 2026-11-16 is a Monday
  def test_weekend_nights_every_weekday
    weekend = %w[2026-11-20 2026-11-21 2026-11-22].map(&D)
    { "2026-11-16" => weekend, "2026-11-17" => weekend, "2026-11-18" => weekend, "2026-11-19" => weekend,
      "2026-11-20" => weekend, # Friday: tonight, Saturday, Sunday
      "2026-11-21" => weekend[1..], # Saturday: tonight and Sunday
      "2026-11-22" => weekend[2..] } # Sunday: tonight only
      .each { |today, nights| assert_equal nights, weekend_nights(D[today]), today }
  end

  def test_next_weekend_nights_every_weekday
    nxt = %w[2026-11-27 2026-11-28 2026-11-29].map(&D)
    (16..22).each { |day| assert_equal nxt, next_weekend_nights(Date.new(2026, 11, day)), "2026-11-#{day}" }
    assert_equal %w[2026-12-04 2026-12-05 2026-12-06].map(&D), next_weekend_nights(D["2026-11-23"]) # Monday moves on
  end

  def test_month_end
    # Thu 2026-04-30: weekend across the month change
    assert_equal %w[2026-05-01 2026-05-02 2026-05-03].map(&D), weekend_nights(D["2026-04-30"])
    assert_equal %w[2026-05-08 2026-05-09 2026-05-10].map(&D), next_weekend_nights(D["2026-04-30"])
    # Sat 2026-01-31: Sunday is in February
    assert_equal %w[2026-01-31 2026-02-01].map(&D), weekend_nights(D["2026-01-31"])
    # Fri 2027-02-26 (no Feb 29 in 2027) and 2028-02-25 (leap year)
    assert_equal %w[2027-02-26 2027-02-27 2027-02-28].map(&D), weekend_nights(D["2027-02-26"])
    assert_equal %w[2028-02-25 2028-02-26 2028-02-27].map(&D), weekend_nights(D["2028-02-25"])
    assert_equal %w[2028-03-03 2028-03-04 2028-03-05].map(&D), next_weekend_nights(D["2028-02-25"])
  end

  def test_year_end
    # Wed 2026-12-30: Fri Jan 1st
    assert_equal %w[2027-01-01 2027-01-02 2027-01-03].map(&D), weekend_nights(D["2026-12-30"])
    # Sat 2027-01-02 / Sun 2027-01-03
    assert_equal %w[2027-01-02 2027-01-03].map(&D), weekend_nights(D["2027-01-02"])
    assert_equal %w[2027-01-03].map(&D), weekend_nights(D["2027-01-03"])
    # Thu 2026-12-31: Fri 2027-01-01, next weekend 2027-01-08
    assert_equal %w[2027-01-08 2027-01-09 2027-01-10].map(&D), next_weekend_nights(D["2026-12-31"])
    # Sun 2028-12-31 (leap year)
    assert_equal [D["2028-12-31"]], weekend_nights(D["2028-12-31"])
    assert_equal %w[2029-01-05 2029-01-06 2029-01-07].map(&D), next_weekend_nights(D["2028-12-31"])
  end

  def test_invariants_over_three_years
    (D["2026-01-01"]..D["2028-12-31"]).each do |today|
      this, nxt = weekend_nights(today), next_weekend_nights(today)
      refute_empty this
      assert this.all? { |d| d >= today && [5, 6, 0].include?(d.wday) }, today.to_s
      assert_equal [5, 6, 0], nxt.map(&:wday), today.to_s
      assert_equal 7, (nxt[0] - (this[0] - (this[0].wday - 5) % 7)).to_i, today.to_s # the following weekend
      assert nxt.last <= (today >> 1).next_month - (today >> 1).next_month.day, "#{today}: next weekend after end of next month"
    end
  end

  def test_dst_does_not_matter
    # the last Sunday of March / October are DST changes in Paris; dates are calendar days
    assert_equal [D["2026-03-29"]], weekend_nights(D["2026-03-29"])
    assert_equal %w[2026-10-23 2026-10-24 2026-10-25].map(&D), weekend_nights(D["2026-10-19"])
  end

  def test_fixed_clock_keeps_wall_time_in_dst_gap
    ENV["FFCAM_NOW"] = "2026-03-29T02:30:00" # does not exist in Paris
    assert_equal "2026-03-29T02:30:00", Ffcam.isoformat(Ffcam.local_now)
    assert_equal D["2026-03-29"], Ffcam.local_today
    ENV["FFCAM_NOW"] = "2026-11-22"
    assert_equal "2026-11-22T00:00:00", Ffcam.isoformat(Ffcam.local_now)
  ensure
    ENV.delete("FFCAM_NOW")
  end
end
