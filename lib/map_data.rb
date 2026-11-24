# Hut data shaped for the map (used by bin/build-site): FFCAM winter rooms folded into their
# guarded hut.

require "json"
require_relative "couchette"

module MapData
  module_function

  BOOKING_LINKS_FILE = File.join(Couchette::MANUAL_DIR, "booking_links.json")

  # The hut's FFCAM site; else its OSM website (only FFCAM ones for FFCAM huts: OSM may list other
  # sites). The `hut_url` column of the availability CSV.
  def hut_url(hut, osm_website)
    return hut["site"] if Py.truthy?(hut["site"])
    return osm_website if Py.truthy?(osm_website) && (osm_website.include?(".ffcam.fr") || hut.fetch("portal", "FFCAM") != "FFCAM")
    nil
  end

  # Hand-kept card links (catalog/manual/booking_links.json): {hut id => {"site", "booking"}}.
  def load_booking_links(file = BOOKING_LINKS_FILE)
    File.exist?(file) ? JSON.parse(File.read(file, encoding: "UTF-8"))["huts"] : {}
  end

  # Booking form of the FFCAM centrale with the hut already chosen (works for every centrale id;
  # plain page, made to sit in an iframe): last resort for centrale huts without a booking page.
  def centrale_link(id, portal)
    origin = portal == "FFCAM" ? "" : "&apporigin=#{portal}"
    "https://centrale.ffcam.fr/index.php?structure=#{id}&mode=FORM&_lang=FR&init=1#{origin}"
  end

  # The two links of a hut's card: [site, booking]. catalog/manual/booking_links.json first, then:
  #   site     the hut's own website: `website` (catalog/manual/manual_huts.json), else the map URL (FFCAM site,
  #            Open System site, OSM website) unless it is a booking tool (refuge-pro.com).
  #   booking  <name>.ffcam.fr/reservation.html (centrale widget with the hut already chosen),
  #            reservation-hg.html for a « Non Gardé » winter room (same site as its guarded hut);
  #            the Refuge Pro calendar / WP Booking System page (catalog/huts.json `site`); the Open
  #            System site (its widget is on the home page); none for huts only bookable by
  #            phone / mail; else the centrale deep link.
  def links(hut, url, overrides = {})
    portal = hut.fetch("portal", "FFCAM")
    own = overrides.fetch(hut["id"], {})
    site = own["site"] || hut["website"] || (url unless url.to_s.include?("refuge-pro.com"))
    booking = own["booking"] ||
      if site.to_s.include?(".ffcam.fr")
        site.sub(%r{/?\z}, "/") + (hut["type"] == "refuge_non_garde" ? "reservation-hg.html" : "reservation.html")
      elsif %w[REFUGEPRO WPBS OPENSYSTEM].include?(portal) then hut["site"]
      elsif portal == "MANUAL" then nil
      else centrale_link(hut["id"], portal)
      end
    [site, booking]
  end

  # The centrale gives no capacity for a « Non Gardé » room: its totalAvailability is the free beds
  # again (13/13 one night, 8/8 the next once 5 are booked). Drop it, the map then shows « N pl. »
  # like for Open System huts rather than a false « N / N ».
  CENTRALE_PORTALS = %w[FFCAM VANOISE NEOUVIELLE BOREON].freeze
  def drop_unguarded_capacity(huts)
    huts.each_value do |h|
      next unless h["type"] == "refuge_non_garde" && CENTRALE_PORTALS.include?(h["portal"])
      h["nights"].each_value { |n| n["capacity"] = nil }
    end
    huts
  end

  # One marker per building: the FFCAM « X Non Gardé » entries (winter room, booked under their own
  # id) are folded into their guarded hut (same Couchette.norm name): each night of the guarded hut gets
  # a "winter" object, the map shows it when the guarded part is closed. Without a guarded
  # sibling in the list (Goûter, Tête Rousse…), a winter room stays a hut of its own.
  def merge_winter_rooms(huts)
    guarded = huts.values.reject { |h| h["type"] == "refuge_non_garde" }.group_by { |h| Couchette.norm(h["name"]) }
    huts.values.select { |h| h["type"] == "refuge_non_garde" }.each do |w|
      g = guarded[Couchette.norm(w["name"])]&.first or next
      w["nights"].each { |d, n| (g["nights"][d] ||= {})["winter"] = n }
      g["winterId"] = w["id"]
      g["winterBooking"] = w["booking"] if w["booking"]
      huts.delete(w["id"])
    end
    huts
  end
end
