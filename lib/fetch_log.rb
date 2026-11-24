# Fetch log: did each hut's availability fetch go well? (feeds the /releves/ page)
#
# For every run, each hut gets a state:
#   ok    the source answered with nights
#   warn  the source answered, but with no night at all (often a format change on the source side)
#   err   the request failed (timeout, HTTP error, page without data...)
#   skip  not fetched: hut without online booking we can read (portal MANUAL)
#
# history/fetch_log.json (on the `data` branch, next to the availability history) keeps:
#   last_run      the latest run, with one entry per hut (state, nights received, seconds, message)
#   runs          a summary of the last MAX_RUNS runs: per source counts + the huts with a problem
#   last_success  per hut, the time of the latest ok / warn fetch
# Written by `bin/fetch-availability --history` (or to another file with --log FILE).

require "fileutils"
require "json"
require_relative "couchette"

module FetchLog
  extend self

  LOG_FILE = File.join(Couchette::ROOT, "history", "fetch_log.json")
  MAX_RUNS = 48
  SOURCE_ORDER = %w[FFCAM VANOISE NEOUVIELLE BOREON OPENSYSTEM REFUGEPRO WPBS MANUAL].freeze

  # -> [state, nights received, message]
  def classify(hut, data, err)
    return ["skip", nil, "Non relevé : réservation hors ligne (téléphone, email, formulaire)"] if hut["portal"] == "MANUAL"
    return ["err", 0, err[0, 300]] if err
    data ||= {}
    days = Py.either(data["opening"], {}).keys | Py.either(data["free"], {}).keys
    return ["warn", 0, "Réponse vide : aucune nuit dans la réponse"] if days.empty?
    known = data["opening"].values.select { |v| Py.truthy?(v) && v != "UNKNOW" }
    if known.empty? # normal for a hut closed for the season: informational only
      return ["ok", days.size, "Pas de calendrier d'ouverture publié sur la période (refuge fermé ?)"]
    end
    ["ok", days.size, ""]
  end

  # What started this run: the workflow_dispatch "source" input (cron-job.org, button),
  # else the GitHub Actions event name, else 'local'.
  def trigger
    return Couchette.env("TRIGGER_SOURCE") if Couchette.env("TRIGGER_SOURCE")
    { "push" => "push sur main", "workflow_dispatch" => "manuel (Actions)" }
      .fetch(Couchette.env("GITHUB_EVENT_NAME"), "local")
  end

  # results: [[hut, data, error]]; timings: {hut_id => seconds}. Returns the run summary.
  def record(results, timings, fetched_at, seconds, path = LOG_FILE)
    log = File.exist?(path) ? JSON.parse(File.read(path, encoding: "UTF-8")) : {}
    huts, sources, problems = [], {}, []
    results.each do |hut, data, err|
      state, nights, msg = classify(hut, data, err)
      src = hut.fetch("portal", "FFCAM")
      s = sources[src] ||= { "total" => 0, "ok" => 0, "warn" => 0, "err" => 0, "skip" => 0, "seconds" => 0.0 }
      s["total"] += 1
      s[state] += 1
      s["seconds"] = Py.round(s["seconds"] + timings.fetch(hut["id"], 0.0), 2)
      huts << { "id" => hut["id"], "state" => state, "nights" => nights, "seconds" => Py.round(timings.fetch(hut["id"], 0.0), 2), "msg" => msg }
      problems << { "id" => hut["id"], "state" => state, "msg" => msg } if %w[err warn].include?(state)
      (log["last_success"] ||= {})[hut["id"]] = fetched_at if %w[ok warn].include?(state)
    end
    order = ->(k) { SOURCE_ORDER.index(k) || 99 }
    run = { "at" => fetched_at, "seconds" => Py.round(seconds, 1), "trigger" => trigger,
            "requests" => huts.count { |h| h["state"] != "skip" },
            "sources" => Py.sorted(sources.keys) { |k| order.(k) }.to_h { |k| [k, sources[k]] },
            "problems" => problems }
    log["last_run"] = run.except("problems").merge("huts" => huts)
    log["runs"] = ([run] + log.fetch("runs", []))[0, MAX_RUNS]
    # one small item per line: git stores only the lines that changed
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, Py.dumps(log, ensure_ascii: false, indent: 1) + "\n")
    run
  end

  def load(path = LOG_FILE)
    File.exist?(path) ? JSON.parse(File.read(path, encoding: "UTF-8")) : nil
  end
end
