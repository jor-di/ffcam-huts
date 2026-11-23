require_relative "test_helper"
require File.join(RB, "map_data")

# rb/map_data.rb: FFCAM winter rooms folded into their guarded hut.
class TestMapData < Minitest::Test
  def hut(id, name, type, nights)
    [id, { "id" => id, "name" => name, "type" => type, "nights" => nights }]
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
    assert_equal({ "opening" => "CLOSE", "winter" => { "opening" => "OPEN", "free" => 20 } }, huts["G"]["nights"]["d1"])
  end
end
