#!/usr/bin/env ruby
# Build an interactive map (map.html) from an availability CSV made by ffcam_availability.rb,
# and the fetch log page (releves/index.html next to it) from history/fetch_log.json.
#
# Usage:
#   rb/build_map.rb                          # latest ffcam_*.csv in this folder
#   rb/build_map.rb ffcam_2026-11-21.csv -o weekend.html
#
# Open the HTML file in a browser (it needs internet access for the map tiles).

require "fileutils"
require "optparse"
require_relative "ffcam"
require_relative "fetch_log"
require_relative "map_data"

def to_int(v)
  v.nil? || v == "" ? nil : Integer(v, 10)
end

# JSON (UTF-8 kept), safe inside a <script> element
def script_json(data)
  Py.dumps(data, ensure_ascii: false).gsub("</", "<\\/")
end

def main
  args = { output: File.join(Ffcam::ROOT, "map.html"), ign_key: Ffcam.secret("IGN_API_KEY"), log: FetchLog::LOG_FILE }
  parser = OptionParser.new do |o|
    o.banner = "Usage: rb/build_map.rb [csv] [-o OUTPUT] [--ign-key KEY] [--log LOG] [--log-output PATH]"
    o.on("-o", "--output OUTPUT") { |v| args[:output] = v }
    o.on("--ign-key KEY", "IGN API key to add the SCAN 25 layer (default: secrets.env or env IGN_API_KEY); it ends up in the HTML") { |v| args[:ign_key] = v }
    o.on("--log LOG", "fetch log to show (default: history/fetch_log.json)") { |v| args[:log] = v }
    o.on("--log-output PATH", "fetch log page (default: releves/index.html next to the map)") { |v| args[:log_output] = v }
  end
  args[:csv] = Ffcam.parse_args(parser, positional: 1)[0]

  path = args[:csv] || Dir.glob(File.join(Ffcam::ROOT, "ffcam_*.csv")).max_by { |f| File.mtime(f) }
  abort("No CSV found: run rb/ffcam_availability.rb first.") unless path

  huts, dates, fetched_at = {}, [], nil
  Py.csv_dicts(File.read(path, encoding: "UTF-8")).each do |r|
    next unless Py.truthy?(r["lat"])
    fetched_at = r["fetched_at"]
    dates << r["date"] unless dates.include?(r["date"])
    hut = huts[r["hut_id"]] ||= {
      "id" => r["hut_id"], "name" => r["name"], "type" => r["type"],
      "lat" => Py.float(r["lat"]), "lon" => Py.float(r["lon"]), "ele" => to_int(r["ele"]),
      "maxPax" => to_int(r["max_pax_per_booking"]), "url" => Py.either(r["hut_url"], nil), "phone" => Py.either(r["phone"], nil),
      "email" => Py.either(r["email"], nil), "c2c" => Py.either(r["c2c_url"], nil), "skitour" => Py.either(r["skitour_url"], nil),
      "portal" => Py.either(r["portal"], "FFCAM"), "nights" => {},
    }
    hut["nights"][r["date"]] = {
      "opening" => Py.either(r["opening"], nil), "free" => to_int(r["free_beds"]),
      "capacity" => to_int(r["capacity"]), "error" => Py.either(r["error"], nil), "booking" => Py.either(r["booking"], nil),
    }
  end

  MapData.merge_winter_rooms(huts)
  data = { "dates" => dates.sort, "fetchedAt" => fetched_at, "source" => File.basename(path), "huts" => huts.values,
           "ignKey" => args[:ign_key] }
  template = File.read(File.join(Ffcam::ROOT, "map_template.html"), encoding: "UTF-8")
  html = template.gsub("__DATA__") { script_json(data) }
  FileUtils.mkdir_p(File.dirname(args[:output]))
  File.write(args[:output], html)
  warn "Wrote #{args[:output]} (#{huts.size} huts, nights: #{data['dates'].join(', ')})"
  build_log_page(args, template)
  build_about_page(args, template, data)
end

# The /a-propos/ page: what the site is for, its sources (huts on the map per booking system).
def build_about_page(args, map_template, data)
  portals = data["huts"].each_with_object(Hash.new(0)) { |h, acc| acc[h["portal"]] += 1 }
  about = { "total" => data["huts"].size, "portals" => portals.sort.to_h, "fetchedAt" => data["fetchedAt"] }
  favicon = map_template.match(%r{<link rel="icon" type="image/svg\+xml" href="([^"]+)"})
  page = File.read(File.join(Ffcam::ROOT, "about_template.html"), encoding: "UTF-8")
  page = page.gsub("__FAVICON__") { favicon ? favicon[1] : "" }.gsub("__ABOUT__") { script_json(about) }
  out = File.join(File.dirname(args[:output]), "a-propos", "index.html")
  FileUtils.mkdir_p(File.dirname(out))
  File.write(out, page)
  warn "Wrote #{out} (about page)"
end

# The /releves/ page: did each hut's fetch go well (see fetch_log.rb).
def build_log_page(args, map_template)
  log = FetchLog.load(args[:log]) || {}
  names = Ffcam.load_huts["huts"].to_h do |h|
    [h["id"], { "name" => h["name"].gsub("  ", " ").gsub(" (FFCAM)", ""), "portal" => h.fetch("portal", "FFCAM") }]
  end
  data = { "last_run" => log["last_run"], "runs" => log.fetch("runs", []), "last_success" => log.fetch("last_success", {}), "huts" => names }
  favicon = map_template.match(%r{<link rel="icon" type="image/svg\+xml" href="([^"]+)"})
  page = File.read(File.join(Ffcam::ROOT, "log_template.html"), encoding: "UTF-8")
  page = page.gsub("__FAVICON__") { favicon ? favicon[1] : "" }
  page = page.gsub("__LOG__") { script_json(data) }
  out = args[:log_output] || File.join(File.dirname(args[:output]), "releves", "index.html")
  FileUtils.mkdir_p(File.dirname(out))
  File.write(out, page)
  state = data["last_run"] ? "run of #{data['last_run']['at']}" : "no run yet"
  warn "Wrote #{out} (fetch log, #{state})"
end

main if $PROGRAM_NAME == __FILE__
