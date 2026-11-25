require_relative "test_helper"
require File.join(LIB, "github_issues")
# the scripts define their helpers as top-level methods; `main` only runs when executed
load File.join(BIN, "check-fetch-alerts")
load File.join(BIN, "check-links")

# Mail alerts (GitHub issues): huts failing N runs in a row, link check verdicts. Offline.
class TestAlerts < Minitest::Test
  def run_with(*ids)
    { "problems" => ids.map { |id| { "id" => id, "state" => "err", "msg" => "TimeoutError" } } }
  end

  def test_failing_needs_every_run
    log = { "runs" => [run_with("A", "B")] + [run_with("A")] * 9 + [run_with] }
    assert_equal %w[A], FetchAlerts.failing(log).map { |p| p["id"] } # B: only in the latest run
    assert_equal [], FetchAlerts.failing({ "runs" => [run_with("A")] * 9 }) # fewer than 10 runs
    assert_equal [], FetchAlerts.failing(nil)
  end

  def test_fetch_alert_body
    log = { "last_success" => { "A" => "2026-11-20T09:00:00" } }
    body = FetchAlerts.body([{ "id" => "A", "state" => "err", "msg" => "a | b" }], log, { "A" => { "name" => "Refuge A", "portal" => "FFCAM" } })
    assert_includes body, "1 refuge en échec sur les 10 derniers relevés."
    assert_includes body, "| Refuge A | FFCAM | err | 2026-11-20T09:00:00 | a / b |"
  end

  def test_link_verdicts
    t = ->(kind, url, id = "BK_STRUCTURE:112") { { "id" => id, "kind" => kind, "url" => url } }
    assert_equal "ok", LinkCheck.verdict(t.("booking", "https://x.ffcam.fr/reservation.html"), "https://x.ffcam.fr/reservation.html", "structure:'112'")[0]
    assert_equal "warn", LinkCheck.verdict(t.("booking", "https://x.ffcam.fr/reservation.html"), "https://x.ffcam.fr/reservation.html", "travaux")[0]
    assert_equal "err", LinkCheck.verdict(t.("site", "https://inconnu.ffcam.fr/"), "https://www.ffcam.fr/", "")[0]
    assert_equal "ok", LinkCheck.verdict(t.("site", "https://refugelaval.com/"), "https://www.refugelaval.com/", "")[0]
  end

  def test_link_failures
    assert_equal "warn", LinkCheck.failure("HTTPError: HTTP Error 403: Forbidden")[0] # refuses robots
    assert_equal "warn", LinkCheck.failure("HTTPError: HTTP Error 429: Too Many Requests")[0]
    assert_equal "err", LinkCheck.failure("HTTPError: HTTP Error 404: Not Found")[0]
    assert_equal "err", LinkCheck.failure("URLError: <urlopen error [Errno -2] Name or service not known>")[0]
  end

  def test_link_targets
    hut = { "id" => "RP-x", "name" => "Refuge X", "portal" => "REFUGEPRO", "site" => "https://refuge-pro.com/embed/calendrier/x", "website" => "https://x.fr/" }
    assert_equal [%w[site https://x.fr/], %w[booking https://refuge-pro.com/embed/calendrier/x]],
                 LinkCheck.targets([hut], {}, {}).map { |r| [r["kind"], r["url"]] }
  end

  def test_page_targets
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a-propos.html"), <<~HTML)
        <link href="https://fonts.googleapis.com/css2?family=Inter" rel="stylesheet">
        <a href="https://www.ffcam.fr/periode-hors-gardiennage.html" target="_blank">mode d'emploi</a>
        <a class="gh" href="https://github.com/jor-di/ffcam-huts">code</a> <a href="../releves/">relevés</a>
        <a href="https://www.ffcam.fr/periode-hors-gardiennage.html">encore</a> <a href="${esc(h.site)}">x</a>
      HTML
      got = LinkCheck.page_targets(dir)
      assert_equal %w[https://www.ffcam.fr/periode-hors-gardiennage.html https://github.com/jor-di/ffcam-huts], got.map { |t| t["url"] }
      assert_equal ["Page « À propos »", "page"], got.first.values_at("name", "kind")
      assert_equal "ok", LinkCheck.verdict(got.first, "https://www.ffcam.fr/periode-hors-gardiennage.html", "")[0]
    end
    assert_includes LinkCheck.page_targets.map { |t| t["url"] }, "https://www.ffcam.fr/periode-hors-gardiennage.html" # the real templates
  end

  def test_issue_sync_without_token_only_prints
    env = %w[GITHUB_TOKEN GITHUB_REPOSITORY].to_h { |k| [k, ENV.delete(k)] }
    out = capture_io { assert_equal :local, GitHubIssues.sync(label: "x", title: "X", body: "problème") }
    assert_includes out[1], "problème"
  ensure
    env.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end
end
