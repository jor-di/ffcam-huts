require_relative "test_helper"
require "socket"
require "timeout"

# Politeness limiter, thread pool, HTTP layer (against a local server) and command line.
class TestHttp < Minitest::Test
  # Run `count` fake requests per host through Ffcam.polite with 8 workers; returns
  # {host => [[start, end], ...]} and the highest number of simultaneous requests per host.
  def run_polite(hosts, count, duration: 0.05, fail_at: nil)
    lock, active, peak, spans = Mutex.new, Hash.new(0), Hash.new(0), Hash.new { |h, k| h[k] = [] }
    jobs = hosts.product((0...count).to_a)
    error = nil
    begin
      Ffcam.pool_map(jobs, 8) do |host, i|
        Ffcam.polite("https://#{host}/page?#{i}") do
          t0 = Ffcam.clock
          lock.synchronize { peak[host] = [peak[host], active[host] += 1].max }
          sleep duration
          lock.synchronize { active[host] -= 1; spans[host] << [t0, Ffcam.clock] }
          raise "boom #{host} #{i}" if fail_at == [host, i]
        end
      end
    rescue RuntimeError => e
      error = e
    end
    [spans, peak, error]
  end

  def test_polite_limits_concurrency_and_spaces_starts
    hosts = %w[a.polite.test b.polite.test]
    spans, peak, = run_polite(hosts, 5, duration: 0.4) # requests slower than the gap: they overlap
    hosts.each do |host|
      starts = spans[host].map(&:first).sort
      assert_equal 5, starts.size
      assert_equal Ffcam::PER_HOST_LIMIT, peak[host], "#{host}: at most 2 at a time (and 2 reached)"
      starts.each_cons(2) { |x, y| assert_operator y - x, :>=, Ffcam::PER_HOST_GAP - 0.01, "#{host}: gap between starts" }
    end
    # the two hosts don't wait for each other (upper time bounds are relaxed on CI runners,
    # which can be slow: a flaky timing test must not block the hourly update)
    assert_operator (spans["a.polite.test"].map(&:first).min - spans["b.polite.test"].map(&:first).min).abs, :<, ENV["CI"] ? 1.0 : 0.2
  end

  def test_polite_exception_releases_the_slot_without_deadlock
    Timeout.timeout(10) do
      spans, peak, error = run_polite(%w[c.polite.test], 6, fail_at: ["c.polite.test", 1])
      assert_equal "boom c.polite.test 1", error&.message # raised again once every item ran
      assert_equal 6, spans["c.polite.test"].size
      assert_operator peak["c.polite.test"], :<=, 2
      # both slots are free again
      2.times.map { Thread.new { Ffcam.polite("https://c.polite.test/") { :ok } } }.each { |t| assert_equal :ok, t.value }
    end
  end

  def test_pool_map
    assert_equal (1..20).map { |i| i * 2 }, Ffcam.pool_map((1..20).to_a, 8) { |i| sleep(rand / 100); i * 2 } # input order
    assert_equal [], Ffcam.pool_map([], 4) { |i| i }
    ran = Queue.new
    error = assert_raises(KeyError) do
      Ffcam.pool_map((0..9).to_a, 3) { |i| ran << i; raise KeyError, "item #{i}" if [7, 4].include?(i) }
    end
    assert_equal "item 4", error.message # the first failing item, after all ran
    assert_equal 10, ran.size
    assert_raises(ArgumentError) { Ffcam.pool_map([1], 0) { |i| i } }
  end

  # A local HTTP server: `handler` gets the request line and returns the raw response (or
  # sleeps). Yields its base URL; returns the number of connections received.
  def with_server(handler)
    server = TCPServer.new("127.0.0.1", 0)
    hits = 0
    thread = Thread.new do
      loop do
        client = server.accept
        hits += 1
        Thread.new(client) do |c|
          request = c.gets.to_s
          while (line = c.gets) && line != "\r\n"; end
          response = handler.call(request)
          c.write(response) if response
        rescue IOError, SystemCallError
          nil
        ensure
          c.close
        end
      end
    end
    yield "http://127.0.0.1:#{server.addr[1]}"
    hits
  ensure
    thread&.kill
    server&.close
  end

  def response(status, body = "", headers = {})
    head = headers.merge("Content-Length" => body.bytesize, "Connection" => "close").map { |k, v| "#{k}: #{v}\r\n" }.join
    "HTTP/1.1 #{status}\r\n#{head}\r\n#{body}"
  end

  def test_read_timeout_is_not_retried_by_net_http
    hits = with_server(->(_req) { sleep 1.5; nil }) do |base|
      t0 = Ffcam.clock
      error = assert_raises(Ffcam::FetchError) { Ffcam.fetch("#{base}/slow", nil, Ffcam::HEADERS, 0.5) }
      assert_equal "TimeoutError: The read operation timed out", Ffcam.error_text(error)
      assert_operator Ffcam.clock - t0, :<, 0.9 unless ENV["CI"] # one timeout, not two (also proven by hits == 1)
    end
    assert_equal 1, hits
  end

  def test_http_errors_and_redirects
    handler = lambda do |req|
      case req
      when %r{\A\w+ /502} then response("502 Bad Gateway")
      when %r{\APOST /moved} then response("302 Found", "", "Location" => "/target")
      when %r{\APOST /temporary} then response("307 Temporary Redirect", "", "Location" => "/target")
      when %r{\AGET /target} then response("200 OK", "été".b)
      else response("404 Not Found")
      end
    end
    with_server(handler) do |base|
      error = assert_raises(Ffcam::FetchError) { Ffcam.fetch("#{base}/502") }
      assert_equal "HTTPError: HTTP Error 502: Bad Gateway", Ffcam.error_text(error)
      final, body = Ffcam.fetch("#{base}/moved", "a=1") # a POST redirected with 302 becomes a GET
      assert_equal ["#{base}/target", "été"], [final, body.force_encoding("UTF-8")]
      assert_raises(Ffcam::FetchError) { Ffcam.fetch("#{base}/temporary", "a=1") } # 307: not followed for a POST
    end
  end

  def test_connection_refused
    port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    error = assert_raises(Ffcam::FetchError) { Ffcam.fetch("http://127.0.0.1:#{port}/", nil, Ffcam::HEADERS, 2) }
    assert_equal "URLError: <urlopen error [Errno 111] Connection refused>", Ffcam.error_text(error)
  end

  def test_retries_wait_2_then_4_seconds
    waits = []
    Ffcam.singleton_class.alias_method(:real_pause, :pause)
    Ffcam.define_singleton_method(:pause) { |s| waits << s }
    calls = 0
    assert_raises(RuntimeError) { Ffcam.with_retries(3) { calls += 1; raise "down" } }
    assert_equal [3, [2, 4]], [calls, waits]
    calls = 0
    assert_equal :ok, Ffcam.with_retries(3) { (calls += 1) < 2 ? raise("once") : :ok }
  ensure
    Ffcam.singleton_class.alias_method(:pause, :real_pause)
    Ffcam.singleton_class.remove_method(:real_pause)
  end

  # Ffcam.parse_args on a given command line: [result, exit status, stderr]
  def parse(argv, positional: 0)
    saved = ARGV.dup
    ARGV.replace(argv)
    parser = OptionParser.new("Usage: test") do |o|
      o.on("--nights N", Integer)
      o.on("--date YYYY-MM-DD", /\A\d{4}-\d\d-\d\d\z/)
    end
    status = 0
    result = nil
    _, err = capture_io do
      result = Ffcam.parse_args(parser, positional: positional)
    rescue SystemExit => e
      status = e.status
    end
    [result, status, err]
  ensure
    ARGV.replace(saved)
  end

  def test_parse_args
    assert_equal [["file.csv"], 0], parse(%w[--nights 2 file.csv], positional: 1)[0, 2]
    [%w[--nights abc], %w[--bogus], %w[extra], %w[--date 2026-07-03T10:00], %w[--nights]].each do |argv|
      _, status, err = parse(argv)
      assert_equal 2, status, argv.join(" ")
      assert_match(/\AUsage: test\n.*: error: /, err)
    end
  end
end
