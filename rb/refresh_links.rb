#!/usr/bin/env ruby
# Find each hut's page on Camptocamp (C2C) and Skitour, written to hut_links.json.
#
# Run after rb/refresh_coordinates.rb: huts are matched by position (and name) around
# their GPS coordinates.
#
#   - Camptocamp: public API, no key. Searches C2C huts within ~1.5 km of each hut.
#   - Skitour: official API, needs your personal key (free, from your skitour.fr profile page):
#       read from secrets.env (SKITOUR_API_KEY=...), the environment, or --skitour-key xxxx
#     Without a key, Skitour links are kept from the previous run (or left empty).
#     Skitour's terms ask that pages using its data link to skitour.fr: the map does.
#
# Usage:
#   rb/refresh_links.rb

require "optparse"
require_relative "ffcam"
require_relative "difflib"

COORDS = File.join(Ffcam::ROOT, "hut_coordinates.json")
OUTPUT = File.join(Ffcam::ROOT, "hut_links.json")
UA = { "User-Agent" => "ffcam-huts-script", "Accept" => "application/json" }.freeze
C2C_API = "https://api.camptocamp.org/waypoints"
C2C_PAGE = "https://www.camptocamp.org/waypoints/%<id>s"
SKITOUR_API = "https://skitour.fr/api/refuges"
SKITOUR_PAGE = "https://skitour.fr/refuges/%<id>s"
RADIUS_M = 1500       # search radius around the hut
MAX_DIST_M = 400      # a candidate this close is accepted even with a different name
MIN_NAME_SCORE = 0.6  # name similarity needed for candidates further away

def get_json(url, headers = nil)
  Py.loads(Ffcam.fetch(url, nil, UA.merge(headers || {}))[1])
end

def distance_m(lat1, lon1, lat2, lon2)
  p = Math::PI / 180
  a = (Math.sin((lat2 - lat1) * p / 2)**2 +
       Math.cos(lat1 * p) * Math.cos(lat2 * p) * Math.sin((lon2 - lon1) * p / 2)**2)
  12_742_000 * Math.asin(Math.sqrt(a))
end

def name_score(a, b)
  Difflib::SequenceMatcher.new(Ffcam.norm(a), Ffcam.norm(b)).ratio
end

# candidates: [[id, name, lat, lon]] -> [id, name, distance] of the best one, or nil.
def best_match(hut, coords, candidates)
  scored = []
  candidates.each do |cid, cname, clat, clon|
    d = distance_m(coords["lat"], coords["lon"], clat, clon)
    s = name_score(hut["name"], cname)
    scored << [s - d / RADIUS_M, cid, cname, Py.round(d)] if d <= MAX_DIST_M || (s >= MIN_NAME_SCORE && d <= RADIUS_M)
  end
  return nil if scored.empty?
  _, cid, cname, d = scored.max
  [cid, cname, d]
end

# ---------- Camptocamp ----------
def to_mercator(lat, lon)
  x = lon * 20_037_508.34 / 180
  y = Math.log(Math.tan((90 + lat) * Math::PI / 360)) * 20_037_508.34 / Math::PI
  [x, y]
end

def from_mercator(x, y)
  lon = x / 20_037_508.34 * 180
  lat = 360 / Math::PI * Math.atan(Math.exp(y / 20_037_508.34 * Math::PI)) - 90
  [lat, lon]
end

def c2c_candidates(coords)
  x, y = to_mercator(coords["lat"], coords["lon"])
  r = RADIUS_M * 1.45 # mercator metres are stretched by ~1/cos(lat) at 45°N
  bbox = [x - r, y - r, x + r, y + r].map { |v| Py.str(v) }.join(",")
  url = "#{C2C_API}?bbox=#{bbox}&wtyp=hut,gite,shelter&limit=50"
  get_json(url).fetch("documents", []).map do |w|
    locales = w.fetch("locales", []).to_h { |loc| [loc["lang"], loc["title"]] }
    name = Py.either(locales["fr"], locales.empty? ? "" : locales.values.first)
    gx, gy = Py.loads(w["geometry"]["geom"])["coordinates"][0, 2]
    [w["document_id"], name, *from_mercator(gx, gy)]
  end
end

# ---------- Skitour ----------
# Skitour huts as [id, name, lat, lon]; entries without an id, a name or usable coordinates
# ({"latlon": [lat, lon]}, numbers or numeric strings) are skipped.
def skitour_candidates(key)
  data = get_json(SKITOUR_API, { "cle" => key })
  raise "Skitour API error: #{data['ERROR']}" if data.is_a?(Hash) && Py.truthy?(data["ERROR"])
  return [] unless data.is_a?(Array)
  data.filter_map do |r|
    next unless r.is_a?(Hash) && r.key?("id") && r.key?("refuge") && r["latlon"].is_a?(Array) && r["latlon"].size >= 2
    [r["id"], r["refuge"], Py.float(r["latlon"][0]), Py.float(r["latlon"][1])]
  rescue ArgumentError, TypeError # not a number
    next
  end
end

def main
  skitour_key = Ffcam.secret("SKITOUR_API_KEY")
  parser = OptionParser.new do |o|
    o.banner = "Usage: rb/refresh_links.rb [--skitour-key KEY]"
    o.on("--skitour-key KEY", "Skitour API key (default: secrets.env or env SKITOUR_API_KEY)") { |v| skitour_key = v }
  end
  Ffcam.parse_args(parser)

  huts = Ffcam.load_huts["huts"]
  abort("hut_coordinates.json not found: run rb/refresh_coordinates.rb first.") unless File.exist?(COORDS)
  coords = JSON.parse(File.read(COORDS, encoding: "UTF-8"))
  previous = File.exist?(OUTPUT) ? JSON.parse(File.read(OUTPUT, encoding: "UTF-8")) : {}
  located = huts.select { |h| coords.key?(h["id"]) }
  links = located.to_h { |h| [h["id"], { "name" => h["name"] }] }

  warn "Camptocamp: searching around #{located.size} huts..."

  c2c = lambda do |hut|
    [hut, best_match(hut, coords[hut["id"]], c2c_candidates(coords[hut["id"]])), nil]
  rescue StandardError => e
    [hut, nil, e.message]
  end

  Ffcam.pool_map(located, 3, &c2c).each do |hut, match, err|
    if err
      warn "  C2C error for #{hut['name']}: #{err}"
      links[hut["id"]]["c2c"] = previous.fetch(hut["id"], {})["c2c"]
    elsif match
      cid, cname, d = match
      links[hut["id"]]["c2c"] = { "url" => format(C2C_PAGE, id: cid), "name" => cname, "distance_m" => d }
    end
  end

  if Py.truthy?(skitour_key)
    warn "Skitour: downloading the hut list..."
    candidates = skitour_candidates(skitour_key)
    warn "  #{candidates.size} Skitour huts"
    located.each do |hut|
      match = best_match(hut, coords[hut["id"]], candidates)
      next unless match
      sid, sname, d = match
      links[hut["id"]]["skitour"] = { "url" => format(SKITOUR_PAGE, id: sid), "name" => sname, "distance_m" => d }
    end
  else
    warn "Skitour: no API key (SKITOUR_API_KEY in secrets.env), keeping previous Skitour links."
    links.each do |hid, link|
      sk = previous.fetch(hid, {})["skitour"]
      link["skitour"] = sk if Py.truthy?(sk)
    end
  end

  File.write(OUTPUT, Py.dumps(links, ensure_ascii: false, indent: 2) + "\n")
  n_c2c = links.values.count { |v| Py.truthy?(v["c2c"]) }
  n_sk = links.values.count { |v| Py.truthy?(v["skitour"]) }
  warn "Wrote #{OUTPUT}: #{n_c2c}/#{links.size} Camptocamp, #{n_sk}/#{links.size} Skitour links"
  links.each_value do |v|
    c = v["c2c"]
    if Py.truthy?(c) && name_score(v["name"], c["name"]) < MIN_NAME_SCORE
      warn "  check C2C match (different name): #{v['name']} -> #{c['name']} (#{c['distance_m']} m)"
    end
    warn "  no C2C page: #{v['name']}" unless Py.truthy?(c)
  end
end

main if $PROGRAM_NAME == __FILE__
