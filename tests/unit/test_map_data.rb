require_relative "test_helper"
require File.join(LIB, "map_data")

# lib/map_data.rb: FFCAM winter rooms folded into their guarded hut.
class TestMapData < Minitest::Test
  def hut(id, name, type, nights)
    [id, { "id" => id, "name" => name, "type" => type, "nights" => nights }]
  end

  def test_km_from_chambery
    assert_equal 0.0, MapData.km_from_chambery(*MapData::CHAMBERY)
    assert_in_delta 45, MapData.km_from_chambery(45.1885, 5.7245), 1.5 # Grenoble
  end

  def test_merge_winter_rooms
    huts = [
      hut("G", "Refuge Albert 1er  (FFCAM)", "refuge", { "d1" => { "opening" => "CLOSE" } }),
      hut("W", "Refuge Albert 1er Non Gardé (FFCAM)", "refuge_non_garde", { "d1" => { "opening" => "OPEN", "free" => 20 } }),
      hut("L", "Refuge du Goûter Non Gardé (FFCAM)", "refuge_non_garde", { "d1" => { "opening" => "OPEN", "free" => 3 } }),
    ].to_h
    MapData.merge_winter_rooms(huts)
    assert_equal %w[G L], huts.keys # alone, a winter room stays a hut
    assert_equal "W", huts["G"]["winterId"]
    refute huts["G"].key?("winterBooking") # no booking link on the winter room here
    assert_equal({ "opening" => "CLOSE", "winter" => { "opening" => "OPEN", "free" => 20 } }, huts["G"]["nights"]["d1"])
  end

  def test_drop_unguarded_capacity
    huts = [
      hut("W", "Refuge de la Pra Non Gardé", "refuge_non_garde", { "d1" => { "opening" => "OPEN", "free" => 8, "capacity" => 8 } }),
      hut("G", "Refuge de la Pra  (FFCAM)", "refuge", { "d1" => { "opening" => "OPEN", "free" => 8, "capacity" => 23 } }),
      hut("C", "Refuge de la Coire", "refuge_non_garde", { "d1" => { "opening" => "OPEN", "free" => 8, "capacity" => 12 } }),
    ].to_h
    huts["W"]["portal"] = huts["G"]["portal"] = "FFCAM"
    huts["C"]["portal"] = "WPBS"
    MapData.drop_unguarded_capacity(huts)
    assert_nil huts["W"]["nights"]["d1"]["capacity"] # centrale « Non Gardé »: total = free beds, meaningless
    assert_equal 23, huts["G"]["nights"]["d1"]["capacity"]
    assert_equal 12, huts["C"]["nights"]["d1"]["capacity"] # other systems keep theirs
  end

  def test_links
    ffcam = "https://refugeduglacierblanc.ffcam.fr/"
    assert_equal [ffcam, ffcam + "reservation.html"], MapData.links({ "portal" => "FFCAM", "site" => ffcam }, ffcam)
    pro = { "portal" => "REFUGEPRO", "site" => "https://refuge-pro.com/embed/calendrier/x", "website" => "https://x.fr/" }
    assert_equal ["https://x.fr/", pro["site"]], MapData.links(pro, pro["site"])
    assert_equal [nil, pro["site"]], MapData.links(pro.except("website"), pro["site"]) # never refuge-pro.com as site
    winter = { "id" => "W", "portal" => "FFCAM", "type" => "refuge_non_garde" }
    assert_equal [ffcam, ffcam + "reservation-hg.html"], MapData.links(winter, ffcam)
    assert_equal [nil, "https://centrale.ffcam.fr/index.php?structure=V&mode=FORM&_lang=FR&init=1&apporigin=VANOISE"],
                 MapData.links({ "id" => "V", "portal" => "VANOISE" }, nil)
    assert_equal [nil, "https://p/"], MapData.links({ "id" => "V", "portal" => "VANOISE" }, nil, { "V" => { "booking" => "https://p/" } })
    assert_equal ["https://selle.fr/", nil], MapData.links({ "portal" => "MANUAL", "website" => "https://selle.fr/" }, "https://selle.fr/contact/")
  end
end
