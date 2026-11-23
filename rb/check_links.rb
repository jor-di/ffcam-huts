#!/usr/bin/env ruby
# Check the links of the huts' cards (« Site du refuge », « ⚡ Résa », see MapData.links): each one
# must answer, and a booking page of the FFCAM centrale must show this hut. Weekly (workflow
# links.yml, started by cron-job.org) or by hand after rb/refresh_huts.rb. About 250 requests,
# with the same politeness limits as the availability fetch.
#
#   rb/check_links.rb                # print the problems
#   rb/check_links.rb --history      # also write history/links.json (shown on /releves/) and
#                                    # sync the GitHub issue « Liens cassés » (with GITHUB_TOKEN)
#
# Per link: ok; warn (answers, but the page doesn't name this hut: booking page without the
# centrale widget, closed for works...); err (no answer, HTTP error, an unknown <name>.ffcam.fr
# site sent to www.ffcam.fr). Only errors go into the issue.

require "fileutils"
require "json"
require "optparse"
require "uri"
require_relative "ffcam"
require_relative "map_data"
require_relative "github_issues"

module LinkCheck
  module_function

  FILE = File.join(Ffcam::ROOT, "history", "links.json")

  # [{id, name, kind ("site" / "booking"), url}] for every hut of huts.json
  def targets(huts, coords, overrides = MapData.load_booking_links)
    huts.flat_map do |h|
      site, booking = MapData.links(h, MapData.hut_url(h, coords.dig(h["id"], "website")), overrides)
      name = h["name"].gsub("  ", " ").gsub(" (FFCAM)", "")
      [["site", site], ["booking", booking]].select { |_, u| u }.map { |k, u| { "id" => h["id"], "name" => name, "kind" => k, "url" => u } }
    end
  end

  # [state, message] for a link that answered (final URL after redirects, page body)
  def verdict(target, final_url, body)
    url = target["url"]
    if url.include?(".ffcam.fr") && URI(final_url).host == "www.ffcam.fr" && !url.include?("www.ffcam.fr")
      return ["err", "renvoie vers www.ffcam.fr (site inconnu)"]
    end
    if target["kind"] == "booking" && (url.include?("centrale.ffcam.fr") || url.end_with?(".ffcam.fr/reservation.html"))
      short = target["id"].sub("BK_STRUCTURE:", "")
      return ["warn", "la page ne montre pas ce refuge (pas de widget de réservation)"] unless body.include?(short)
    end
    ["ok", ""]
  end

  def check(targets)
    urls = targets.map { |t| t["url"] }.uniq
    answers = Ffcam.pool_map(urls, 6) do |u|
      final, body = Ffcam.polite(u) { Ffcam.fetch(u, nil, Ffcam::HEADERS, 20) }
      [final, body]
    rescue StandardError => e
      Ffcam.error_text(e)
    end.then { |list| urls.zip(list).to_h }
    targets.map do |t|
      a = answers[t["url"]]
      state, msg = a.is_a?(String) ? ["err", a[0, 200]] : verdict(t, *a)
      t.merge("state" => state, "msg" => msg)
    end
  end

  def summary(results, at)
    counts = %w[ok warn err].to_h { |s| [s, results.count { |r| r["state"] == s }] }
    { "at" => at, "checked" => results.size, "counts" => counts, "problems" => results.reject { |r| r["state"] == "ok" } }
  end

  def issue_body(errors)
    rows = errors.map { |r| "| #{r['name']} | #{r['kind'] == 'site' ? 'Site du refuge' : 'Résa'} | #{r['url']} | #{r['msg'].gsub('|', '/')} |" }
    ["#{errors.size} lien#{errors.size > 1 ? 's' : ''} cassé#{errors.size > 1 ? 's' : ''} sur les fiches des refuges.", "",
     "| Refuge | Lien | URL | Erreur |", "| --- | --- | --- | --- |", *rows, "",
     "À corriger dans `booking_links.json` (ou `manual_huts.json` pour un site). Détail : https://dernierecouchette.fr/releves/"].join("\n")
  end
end

def main
  history = false
  parser = OptionParser.new do |o|
    o.banner = "Usage: rb/check_links.rb [--history]"
    o.on("--history", "write history/links.json and sync the GitHub issue") { history = true }
  end
  Ffcam.parse_args(parser)
  coords_file = File.join(Ffcam::ROOT, "hut_coordinates.json")
  coords = File.exist?(coords_file) ? JSON.parse(File.read(coords_file, encoding: "UTF-8")) : {}
  results = LinkCheck.check(LinkCheck.targets(Ffcam.load_huts["huts"], coords))
  sum = LinkCheck.summary(results, Ffcam.local_now.strftime("%Y-%m-%dT%H:%M:%S"))
  sum["problems"].each { |r| puts "#{r['state'].ljust(4)} #{r['name']} [#{r['kind']}] #{r['url']} — #{r['msg']}" }
  warn "Links: #{sum['checked']} checked, #{sum['counts']}"
  return unless history
  FileUtils.mkdir_p(File.dirname(LinkCheck::FILE))
  File.write(LinkCheck::FILE, Py.dumps(sum, ensure_ascii: false, indent: 1) + "\n")
  errors = results.select { |r| r["state"] == "err" }
  result = GitHubIssues.sync(label: "liens", title: "Liens cassés", body: errors.empty? ? nil : LinkCheck.issue_body(errors),
                             key: errors.map { |r| r["url"] }.sort.join(","))
  warn "Links issue: #{result}"
end

main if $PROGRAM_NAME == __FILE__
