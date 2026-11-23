#!/usr/bin/env ruby
# Mail alert on huts whose availability fetch keeps failing: a hut in error (err or warn, see
# fetch_log.rb) in each of the last RUNS runs of history/fetch_log.json gets into the GitHub issue
# « Relevés en erreur » (label `releves`, see github_issues.rb: opened, updated when the list
# changes, closed when it is empty). Run by the workflow after each fetch.
#
#   rb/check_fetch_alerts.rb               # GitHub issue (with GITHUB_TOKEN), else print
#   rb/check_fetch_alerts.rb --log FILE

require "optparse"
require_relative "ffcam"
require_relative "fetch_log"
require_relative "github_issues"

module FetchAlerts
  module_function

  RUNS = 10
  SITE = "https://dernierecouchette.fr/releves/"

  # Huts in problem in each of the last `runs` runs (newest first in the log): [{id, state, msg}]
  # as in the latest run. Empty while the log has fewer runs.
  def failing(log, runs = RUNS)
    last = (log || {}).fetch("runs", [])[0, runs]
    return [] if last.size < runs
    ids = last.map { |r| r["problems"].map { |p| p["id"] } }.reduce(:&)
    last[0]["problems"].select { |p| ids.include?(p["id"]) }
  end

  def body(failing, log, names, runs = RUNS)
    rows = failing.map do |p|
      n = names.fetch(p["id"], { "name" => p["id"], "portal" => "?" })
      since = log.dig("last_success", p["id"]) || "jamais"
      "| #{n['name']} | #{n['portal']} | #{p['state']} | #{since} | #{p['msg'].to_s.gsub('|', '/')[0, 160]} |"
    end
    ["#{failing.size} refuge#{failing.size > 1 ? 's' : ''} en échec sur les #{runs} derniers relevés.", "",
     "| Refuge | Source | État | Dernier succès | Message |", "| --- | --- | --- | --- | --- |", *rows, "",
     "Détail : #{SITE}"].join("\n")
  end
end

def main
  path = FetchLog::LOG_FILE
  parser = OptionParser.new do |o|
    o.banner = "Usage: rb/check_fetch_alerts.rb [--log FILE]"
    o.on("--log FILE", "fetch log (default: history/fetch_log.json)") { |v| path = v }
  end
  Ffcam.parse_args(parser)
  log = FetchLog.load(path) or abort("#{path}: no fetch log")
  failing = FetchAlerts.failing(log)
  names = Ffcam.load_huts["huts"].to_h { |h| [h["id"], { "name" => h["name"].gsub("  ", " ").gsub(" (FFCAM)", ""), "portal" => h.fetch("portal", "FFCAM") }] }
  body = failing.empty? ? nil : FetchAlerts.body(failing, log, names)
  result = GitHubIssues.sync(label: "releves", title: "Relevés en erreur", body: body, key: failing.map { |p| p["id"] }.sort.join(","))
  warn "Fetch alert: #{failing.size} hut(s) failing #{FetchAlerts::RUNS} runs in a row (issue: #{result})"
end

main if $PROGRAM_NAME == __FILE__
