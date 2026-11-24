require_relative "test_helper"
require "open3"
require "rbconfig"

# History.record (change detection, pruning) and FetchLog (classify, rotation), in a temp folder.
class TestHistory < Minitest::Test
  HUT = { "id" => "1", "name" => "Refuge Étendard" }.freeze

  def setup
    @dir = Dir.mktmpdir("ffcam-unit")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def data(opening, free, capacity = {})
    { "opening" => opening, "free" => free, "capacity" => capacity }
  end

  def record(results, at, today)
    History.record(results, at, Date.iso8601(today), dir: @dir)
  end

  def csv(month) = File.read(File.join(@dir, "availability_#{month}.csv"))
  def state = JSON.parse(File.read(File.join(@dir, "state.json")))

  def test_baseline_then_only_changes
    first = data({ "2026-11-22" => "OPEN", "2026-11-23" => "OPEN", "2026-11-21" => "OPEN" }, { "2026-11-22" => 3, "2026-11-23" => 0 },
                 { "2026-11-22" => 10, "2026-11-23" => 10 })
    assert_equal 2, record([[HUT, first, nil]], "2026-11-22T18:00:00", "2026-11-22") # past night ignored
    assert_equal "fetched_at,hut_id,date,opening,free_beds,capacity\r\n" \
                 "2026-11-22T18:00:00,1,2026-11-22,OPEN,3,10\r\n2026-11-22T18:00:00,1,2026-11-23,OPEN,0,10\r\n", csv("2026-11")
    assert_equal "{\n\"1|2026-11-22\":[\"OPEN\",3,10],\n\"1|2026-11-23\":[\"OPEN\",0,10]\n}\n",
                 File.read(File.join(@dir, "state.json"))

    assert_equal 0, record([[HUT, first, nil]], "2026-11-22T19:00:00", "2026-11-22") # nothing changed
    second = data({ "2026-11-22" => "OPEN", "2026-11-23" => "OPEN" }, { "2026-11-22" => 3, "2026-11-23" => 1 },
                  { "2026-11-22" => 10, "2026-11-23" => 10 })
    assert_equal 1, record([[HUT, second, nil]], "2026-11-22T20:00:00", "2026-11-22")
    assert_equal "2026-11-22T20:00:00,1,2026-11-23,OPEN,1,10\r\n", csv("2026-11").lines.last
  end

  def test_errors_and_manual_huts_record_nothing
    assert_equal 0, record([[HUT, nil, "TimeoutError: x"], [HUT, data({ "2026-12-01" => "OPEN" }, {}), "err"], [HUT, nil, nil]],
                           "2026-11-22T18:00:00", "2026-11-22")
    refute File.exist?(File.join(@dir, "availability_2026-11.csv"))
    assert_equal({}, state)
  end

  def test_pruning_and_month_files
    d = data({ "2026-11-30" => "OPEN", "2026-12-01" => "CLOSE" }, { "2026-11-30" => 2 })
    record([[HUT, d, nil]], "2026-11-30T23:00:00", "2026-11-30")
    assert_equal %w[1|2026-11-30 1|2026-12-01], state.keys
    # next day: the night of Nov 30 is over and forgotten, even if the source still returns it
    d2 = data({ "2026-11-30" => "OPEN", "2026-12-01" => "OPEN" }, { "2026-11-30" => 2 })
    assert_equal 1, record([[HUT, d2, nil]], "2026-12-01T08:00:00", "2026-12-01")
    assert_equal({ "1|2026-12-01" => ["OPEN", nil, nil] }, state)
    assert_equal "fetched_at,hut_id,date,opening,free_beds,capacity\r\n2026-12-01T08:00:00,1,2026-12-01,OPEN,,\r\n", csv("2026-12")
    # a hut no longer fetched keeps its future nights; past ones go
    assert_equal 0, record([], "2027-01-01T08:00:00", "2027-01-01")
    assert_equal({}, state)
  end

  def test_classify
    manual = { "id" => "M", "portal" => "MANUAL" }
    assert_equal ["skip", nil, "Non relevé : réservation hors ligne (téléphone, email, formulaire)"], FetchLog.classify(manual, nil, nil)
    assert_equal ["err", 0, "x" * 300], FetchLog.classify(HUT, nil, "x" * 400)
    assert_equal ["warn", 0, "Réponse vide : aucune nuit dans la réponse"], FetchLog.classify(HUT, data({}, {}), nil)
    assert_equal "warn", FetchLog.classify(HUT, nil, nil)[0]
    closed = data({ "2026-11-22" => "UNKNOW", "2026-11-23" => nil }, { "2026-11-24" => 0 })
    assert_equal ["ok", 3, "Pas de calendrier d'ouverture publié sur la période (refuge fermé ?)"], FetchLog.classify(HUT, closed, nil)
    assert_equal ["ok", 2, ""], FetchLog.classify(HUT, data({ "2026-11-22" => "OPEN" }, { "2026-11-23" => 1 }), nil)
  end

  def test_fetch_log_record_and_rotation
    path = File.join(@dir, "sub", "fetch_log.json")
    ok = data({ "2026-11-22" => "OPEN" }, { "2026-11-22" => 1 })
    results = [[HUT.merge("portal" => "REFUGEPRO"), ok, nil], [{ "id" => "2" }, nil, "HTTPError: HTTP Error 502: Bad Gateway"],
               [{ "id" => "3", "portal" => "MANUAL" }, nil, nil], [{ "id" => "4", "portal" => "FFCAM" }, ok, nil]]
    timings = { "1" => 0.123456, "2" => 1.0049999, "4" => 2.5 }
    run = nil
    50.times do |i|
      run = FetchLog.record(results, timings, format("2026-11-22T%02d:%02d:00", i / 60, i % 60), 3.14159, path)
    end
    log = JSON.parse(File.read(path))
    assert_equal FetchLog::MAX_RUNS, log["runs"].size
    assert_equal "2026-11-22T00:49:00", log["runs"][0]["at"] # newest first
    assert_equal "2026-11-22T00:02:00", log["runs"][-1]["at"]
    assert_equal %w[FFCAM REFUGEPRO MANUAL], run["sources"].keys # source order, not first seen
    assert_equal({ "total" => 2, "ok" => 1, "warn" => 0, "err" => 1, "skip" => 0, "seconds" => 3.5 }, run["sources"]["FFCAM"])
    assert_equal 3.1, run["seconds"]
    assert_equal 3, run["requests"]
    assert_equal [{ "id" => "2", "state" => "err", "msg" => "HTTPError: HTTP Error 502: Bad Gateway" }], run["problems"]
    assert_equal({ "1" => "2026-11-22T00:49:00", "4" => "2026-11-22T00:49:00" }, log["last_success"])
    assert_equal [0.12, 1.0, 0.0, 2.5], log["last_run"]["huts"].map { |h| h["seconds"] } # rounded to 0.01
    refute log["last_run"].key?("problems")
    assert File.read(path).end_with?("}\n")
    assert_equal log, FetchLog.load(path)
    assert_nil FetchLog.load(File.join(@dir, "missing.json"))
  end

  def test_trigger
    env = %w[TRIGGER_SOURCE GITHUB_EVENT_NAME].to_h { |k| [k, ENV.delete(k)] }
    assert_equal "local", FetchLog.trigger
    ENV["GITHUB_EVENT_NAME"] = "push"
    assert_equal "push sur main", FetchLog.trigger
    ENV["TRIGGER_SOURCE"] = "cron-job.org"
    assert_equal "cron-job.org", FetchLog.trigger
  ensure
    env.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end

  # The availability script writes history/ (the production `data` branch worktree) and the
  # fetch log only with --history. Run on a copy of bin/ and lib/ (data files are in their parent) with one
  # MANUAL hut: no request at all.
  def run_availability(*args)
    root = File.join(@dir, "copy")
    FileUtils.mkdir_p(root)
    FileUtils.cp_r([BIN, LIB], root)
    File.write(File.join(root, "huts.json"), JSON.generate({ "huts" => [
      { "id" => "MANUAL-x", "portal" => "MANUAL", "name" => "Refuge X", "short_name" => "X", "type" => "refuge", "max_pax_per_booking" => nil },
    ] }))
    _, err, status = Open3.capture3(RbConfig.ruby, File.join(root, "bin", "fetch-availability"), "-o", "out.csv", *args, chdir: root)
    assert status.success?, err
    [root, err]
  end

  def test_availability_writes_no_history_by_default
    [[], ["--no-history"]].each do |args|
      root, err = run_availability(*args)
      assert File.exist?(File.join(root, "out.csv"))
      refute File.exist?(File.join(root, "history")), "history/ written with #{args.inspect}"
      assert_match(/History: not recorded/, err)
      FileUtils.rm_rf(root)
    end
  end

  def test_availability_with_history_and_log
    root, = run_availability("--history")
    assert_equal "{\n\n}\n", File.read(File.join(root, "history", "state.json")) # a manual hut records no night
    assert_equal "skip", JSON.parse(File.read(File.join(root, "history", "fetch_log.json")))["last_run"]["huts"][0]["state"]
    FileUtils.rm_rf(root)

    root, = run_availability("--log", "log.json") # only the fetch log, where asked
    assert File.exist?(File.join(root, "log.json"))
    refute File.exist?(File.join(root, "history"))
  end
end
