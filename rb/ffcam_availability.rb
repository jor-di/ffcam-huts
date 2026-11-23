#!/usr/bin/env ruby
# Fetch FFCAM hut availability for the huts listed in huts.json and store it in a CSV.
#
# Run rb/refresh_huts.rb first to create huts.json.
#
# Usage:
#   rb/ffcam_availability.rb                       # this weekend from tonight on + next weekend (Fri, Sat, Sun)
#   rb/ffcam_availability.rb --date 2027-07-03 --nights 2
#   rb/ffcam_availability.rb --date 2027-07-03 -o out.csv
#   rb/ffcam_availability.rb --history -o data/latest.csv   # production (GitHub Actions, deploy/run_update.sh)
#
# The history (history/, a worktree of the production `data` branch) and the fetch log
# (history/fetch_log.json) are only written with --history: a manual run never changes them.
# --log FILE writes the fetch log to FILE instead (with or without --history).

require "optparse"
require_relative "ffcam"
require_relative "history"
require_relative "fetch_log"
require_relative "map_data"

def hut_url(hut, osm_website) = MapData.hut_url(hut, osm_website)

# Monday = 0 ... Sunday = 6
def weekday(date)
  (date.wday + 6) % 7
end

# The Friday, Saturday and Sunday nights of the weekend shown on the map, not over yet.
#
# Mon-Fri: the coming Fri, Sat, Sun. Saturday: Sat (tonight), Sun. From Sunday on: the next
# weekend (Fri, Sat, Sun), since on Sunday people plan for the coming one.
def weekend_nights(today = nil)
  today ||= Ffcam.local_today
  (0...3).map { |i| weekend_friday(today) + i }.select { |d| d >= today }
end

# Friday, Saturday and Sunday nights of the weekend after the current one (the map's
# "avant-dernière couchette" mode). Always inside the fetched window (today -> end of next month).
def next_weekend_nights(today = nil)
  today ||= Ffcam.local_today
  (0...3).map { |i| weekend_friday(today) + 7 + i }
end

# Friday of the weekend shown on the map: this week's from Monday to Saturday,
# the next one from Sunday on (on Sunday, people plan for the coming weekend).
def weekend_friday(today)
  friday = today + (4 - weekday(today)) # Mon=0 ... Fri=4, Sat goes back to yesterday
  weekday(today) == 6 ? friday + 7 : friday # Sunday: jump to next Friday
end

def read_json(path)
  File.exist?(path) ? JSON.parse(File.read(path, encoding: "UTF-8")) : {}
end

def main
  args = { workers: 4, history: false }
  parser = OptionParser.new do |o|
    o.banner = "Usage: rb/ffcam_availability.rb [--date YYYY-MM-DD] [--nights N] [-o OUTPUT] [--workers N] [--history] [--log LOG]"
    o.on("--date YYYY-MM-DD", /\A\d{4}-\d\d-\d\d\z/, "first night (default: this weekend, from tonight)") do |v|
      args[:date] = Date.iso8601(v)
    rescue Date::Error
      raise OptionParser::InvalidArgument, v
    end
    o.on("--nights N", Integer, "number of consecutive nights with --date (default: 1)") { |v| args[:nights] = v }
    o.on("-o", "--output OUTPUT", "CSV path (default: ffcam_<date>.csv)") { |v| args[:output] = v }
    o.on("--workers N", Integer, "parallel requests (default: 4)") do |v|
      raise OptionParser::InvalidArgument, "#{v} (at least 1)" if v < 1
      args[:workers] = v
    end
    o.on("--history", "record changes in history/ and the fetch log in history/fetch_log.json (production runs only;",
         "see history.rb, fetch_log.rb)") { args[:history] = true }
    o.on("--no-history", "don't record them: the default, accepted for compatibility") { args[:history] = false }
    o.on("--log LOG", "write the fetch log to this file (default: history/fetch_log.json with --history, else none)") { |v| args[:log] = v }
  end
  Ffcam.parse_args(parser)

  dates = if args[:date]
            (0...Py.either(args[:nights], 1)).map { |i| args[:date] + i }
          else
            weekend_nights + next_weekend_nights
          end
  start = dates[0]
  output = args[:output] || "ffcam_#{start.iso8601}.csv"
  # FFCAM returns the requested date's month + the next one. By default ask from today, so the
  # history always covers today -> end of next month (the next weekend is always inside);
  # with --date, ask from that date.
  fetch_from = args[:date] ? start : Ffcam.local_today

  huts = Ffcam.load_huts["huts"]
  coords = read_json(File.join(Ffcam::ROOT, "hut_coordinates.json"))
  links = read_json(File.join(Ffcam::ROOT, "hut_links.json")) # from rb/refresh_links.rb
  warn "No hut_coordinates.json: run rb/refresh_coordinates.rb to add GPS columns." if coords.empty?
  warn "#{huts.size} huts, fetching availability for #{dates.map(&:iso8601).join(', ')}..."

  timings = {}
  timings_lock = Mutex.new

  work = lambda do |hut|
    t0 = Ffcam.monotonic # durations are 0 with FFCAM_NOW (tests)
    begin
      [hut, Ffcam.fetch_availability(hut["id"], fetch_from, hut.fetch("portal", "FFCAM"), hut["refugepro"] || hut["wpbs"]), nil]
    rescue StandardError => e # keep going, record the error
      [hut, nil, Ffcam.error_text(e)]
    ensure
      timings_lock.synchronize { timings[hut["id"]] = Ffcam.monotonic - t0 }
    end
  end

  started = Ffcam.monotonic
  results = Ffcam.pool_map(huts, args[:workers], &work)
  elapsed = Ffcam.monotonic - started

  fetched_at = Ffcam.isoformat(Ffcam.local_now)
  if args[:history]
    n = History.record(results, fetched_at)
    warn "History: #{n} changes appended to #{File.basename(History::HISTORY_DIR)}/"
  else
    warn "History: not recorded (--history records it in #{History::HISTORY_DIR})"
  end
  log_path = args[:log] || (args[:history] ? FetchLog::LOG_FILE : nil)
  if log_path
    run = FetchLog.record(results, timings, fetched_at, elapsed, log_path)
    bad = run["sources"].select { |_, v| Py.truthy?(v["err"]) || Py.truthy?(v["warn"]) }
    warn "Fetch log: #{File.basename(log_path)} (#{run['problems'].size} huts with a problem#{bad.empty? ? '' : ": #{Py.repr(bad)}"})"
  end
  rows = []
  errors = 0
  results.each do |hut, data, err|
    errors += 1 if err
    coord = coords.fetch(hut["id"], {})
    link = links.fetch(hut["id"], {})
    dates.each do |d|
      key = d.iso8601
      # nights beyond the returned 2-month window come back empty
      free = data && data["free"][key]
      capacity = data && data["capacity"][key]
      opening = data && data["opening"][key]
      booking = data && Py.either(data["booking"], {})[key]
      booking = "request" if hut["portal"] == "MANUAL" # no online booking: phone / mail / form
      rows << {
        "date" => key,
        "weekday" => d.strftime("%A"),
        "hut_id" => hut["id"],
        "name" => hut["name"],
        "portal" => hut.fetch("portal", "FFCAM"),
        "short_name" => hut.fetch("short_name"),
        "type" => hut.fetch("type"),
        "opening" => opening,
        "free_beds" => free,
        "capacity" => capacity,
        "booked" => free.is_a?(Integer) && capacity.is_a?(Integer) ? capacity - free : nil,
        # UNGUARDED with a booking mode: bookable without a keeper (WPBS « Disponible (non-gardé) »)
        "bookable" => (opening == "OPEN" || (opening == "UNGUARDED" && !booking.nil?)) && Py.truthy?(free),
        # online | waitlist (full, waiting list) | phone (FFCAM: no longer sold online) | request (manual hut;
        # WPBS: bookable, places not shown)
        "booking" => booking,
        "max_pax_per_booking" => hut.fetch("max_pax_per_booking"),
        "lat" => coord["lat"],
        "lon" => coord["lon"],
        "ele" => coord["ele"],
        "hut_url" => hut_url(hut, coord["website"]),
        "c2c_url" => Py.either(link["c2c"], {})["url"],
        "skitour_url" => Py.either(link["skitour"], {})["url"],
        "phone" => hut["phone"],
        "email" => hut["email"],
        "fetched_at" => fetched_at,
        "error" => err,
      }
    end
  end

  rows = Py.sorted(rows) { |r| [r["date"], r["bookable"] ? 0 : 1, -(r["free_beds"] || 0), r["name"]] }
  File.open(output, "w:UTF-8") do |f|
    f.write(Py.csv_line(rows[0].keys))
    rows.each { |r| f.write(Py.csv_line(r.values)) }
  end

  bookable = rows.count { |r| r["bookable"] }
  warn "Wrote #{rows.size} rows to #{output} (#{bookable} bookable hut-nights, #{errors} errors)"
end

main if $PROGRAM_NAME == __FILE__
