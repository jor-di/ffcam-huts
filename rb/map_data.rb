# Hut data shaped for the map (used by rb/build_map.rb): FFCAM winter rooms folded into their
# guarded hut.

require_relative "ffcam"

module MapData
  module_function

  # One marker per building: the FFCAM « X Non Gardé » entries (winter room, booked under their own
  # id) are folded into their guarded hut (same Ffcam.norm name): each night of the guarded hut gets
  # a "winter" object, the map shows it when the guarded part is closed. Without a guarded
  # sibling in the list (Goûter, Tête Rousse…), a winter room stays a hut of its own.
  def merge_winter_rooms(huts)
    guarded = huts.values.reject { |h| h["type"] == "refuge_non_garde" }.group_by { |h| Ffcam.norm(h["name"]) }
    huts.values.select { |h| h["type"] == "refuge_non_garde" }.each do |w|
      g = guarded[Ffcam.norm(w["name"])]&.first or next
      w["nights"].each { |d, n| (g["nights"][d] ||= {})["winter"] = n }
      g["winterId"] = w["id"]
      huts.delete(w["id"])
    end
    huts
  end
end
