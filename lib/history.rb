# Availability history: append-only CSV files recording every change (storage only).
#
# Each availability fetch returns ~2 months of days per hut. For every (hut, night) still to
# come, we compare (opening, free beds, capacity) with the last recorded state and append a
# row only when it changed. The first run records everything (baseline).
#
# Files (in history/):
#   availability_YYYY-MM.csv   one file per month of fetch, columns:
#                              fetched_at, hut_id, date, opening, free_beds, capacity
#   state.json                 last recorded state per "hut_id|date" (to detect changes)
#
# To rebuild the state of any (hut, night) at a given time, take the last row with
# fetched_at <= that time.
#
# Written only by `bin/fetch-availability --history` (production runs): history/ is a
# worktree of the production `data` branch, so a manual run must not touch it.

require "fileutils"
require "json"
require_relative "couchette"

module History
  extend self

  HISTORY_DIR = File.join(Couchette::ROOT, "history")
  FIELDS = %w[fetched_at hut_id date opening free_beds capacity].freeze

  # results: [[hut, data, error]] as returned by fetch-availability. Returns rows appended.
  # `dir` is the history folder (another one in tests).
  def record(results, fetched_at, today = nil, dir: HISTORY_DIR)
    today = (today || Couchette.local_today).iso8601
    state_file = File.join(dir, "state.json")
    FileUtils.mkdir_p(dir)
    state = File.exist?(state_file) ? JSON.parse(File.read(state_file, encoding: "UTF-8")) : {}

    changes = []
    results.each do |hut, data, err|
      next if err || !Py.truthy?(data) # a failed fetch (or a manual hut, nothing fetched) says nothing about availability
      days = data["opening"].keys | data["free"].keys | data["capacity"].keys
      days.select { |d| d >= today }.sort.each do |day|
        value = [data["opening"][day], data["free"][day], data["capacity"][day]]
        key = "#{hut['id']}|#{day}"
        next if state[key] == value
        state[key] = value
        changes << [fetched_at, hut["id"], day, *value]
      end
    end

    # forget nights that are over
    state = state.select { |k, _| k.split("|", 2)[1] >= today }

    unless changes.empty?
      path = File.join(dir, "availability_#{fetched_at[0, 7]}.csv")
      new_file = !File.exist?(path)
      File.open(path, "a:UTF-8") do |f|
        f.write(Py.csv_line(FIELDS)) if new_file
        changes.each { |row| f.write(Py.csv_line(row)) }
      end
    end
    # one "hut|night" per line, so git only stores the lines that changed
    lines = state.sort.map { |k, v| "#{Py.dumps(k)}:#{Py.dumps(v, separators: [',', ':'])}" }
    File.write(state_file, "{\n" + lines.join(",\n") + "\n}\n")
    changes.size
  end
end
