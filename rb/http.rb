# Every network request of the scripts goes through Ffcam.fetch: politeness limiter, retries,
# errors named as in the fetch log, and record / replay for the offline tests (FFCAM_RECORD_DIR,
# FFCAM_REPLAY_DIR, see tests/README.md). Loaded by ffcam.rb.

module Ffcam
  HEADERS = { "User-Agent" => "Mozilla/5.0 (X11; Linux x86_64) ffcam-huts-script" }.freeze

  RECORD_DIR = env("FFCAM_RECORD_DIR")
  REPLAY_DIR = env("FFCAM_REPLAY_DIR")
  abort("FFCAM_RECORD_DIR and FFCAM_REPLAY_DIR can't be used together.") if RECORD_DIR && REPLAY_DIR
  RECORD_LOCK = Mutex.new

  # Politeness: whatever the number of worker threads, each site gets at most PER_HOST_LIMIT
  # requests at a time, and at least PER_HOST_GAP seconds between two request starts.
  PER_HOST_LIMIT = 2
  PER_HOST_GAP = 0.3
  HOST_LOCK = Mutex.new
  HOST_SLOTS = {} # host -> Queue of PER_HOST_LIMIT tokens (a semaphore)
  HOST_NEXT = {}  # host -> earliest start time of its next request

  # A request that failed. `py_type` is a stable error name ("TimeoutError", "HTTPError",
  # "URLError"...): with the message it makes the error text stored in the CSV and on the
  # /releves/ page ("TimeoutError: The read operation timed out"). These names and messages
  # come from the first (Python) version; they are kept so that the fetch log history stays
  # consistent and the recorded failures of tests/fixtures/ replay as before.
  class FetchError < StandardError
    attr_reader :py_type

    def initialize(py_type, message)
      @py_type = py_type
      super(message)
    end
  end

  # A request absent from FFCAM_REPLAY_DIR. Not a StandardError, so that the scripts'
  # `rescue StandardError` (retries, per-hut errors) don't turn it into an ordinary failure: the run stops.
  class ReplayMissing < Exception; end # rubocop:disable Lint/InheritException

  # "<type>: <message>" of an error, as shown in the CSV and the fetch log
  def error_text(e)
    "#{e.respond_to?(:py_type) ? e.py_type : e.class.name}: #{e.message}"
  end

  # Wait for a free slot and the minimum gap for this URL's site, then run the request.
  def polite(url)
    return yield if REPLAY_DIR # no server to be gentle with
    host = URI.parse(url).host&.downcase
    slots = HOST_LOCK.synchronize do
      HOST_SLOTS[host] ||= Queue.new.tap { |q| PER_HOST_LIMIT.times { q << true } }
    end
    slots.pop
    begin
      delay = HOST_LOCK.synchronize do # reserve the next start time for this site
        now = clock
        start = [now, HOST_NEXT.fetch(host, 0.0)].max
        HOST_NEXT[host] = start + PER_HOST_GAP
        start - now
      end
      sleep(delay) if delay.positive?
      yield
    ensure
      slots << true
    end
  end

  # sleep between retries, skipped when replaying.
  def pause(seconds)
    sleep(seconds) unless REPLAY_DIR
  end

  # Stable id of a request: sha1 of "METHOD\nURL\nBODY" (BODY empty for a GET). Headers are left out.
  def fixture_key(method, url, body)
    Digest::SHA1.hexdigest("#{method}\n#{url}\n#{body}".encode(Encoding::UTF_8))
  end

  def read_index(folder)
    path = File.join(folder, "index.json")
    File.exist?(path) ? JSON.parse(File.read(path, encoding: "UTF-8")) : {}
  end

  # Response bodies are stored gzip-compressed, without a timestamp in the header, so that
  # recording the same body twice gives the same file.
  def gzip(content)
    gz = Zlib.gzip(content, level: 9)
    gz[4, 4] = "\0\0\0\0".b # MTIME field: none
    gz
  end

  # Save one outcome to FFCAM_RECORD_DIR: index.json entry + bodies/<key>.gz. The last outcome of a request wins.
  def record(method, url, body, entry, content = nil)
    key = fixture_key(method, url, body)
    entry = { "method" => method, "url" => url, "body" => body }.merge(entry)
    RECORD_LOCK.synchronize do
      FileUtils.mkdir_p(File.join(RECORD_DIR, "bodies"))
      file = File.join(RECORD_DIR, "bodies", "#{key}.gz")
      if content
        entry["file"] = "bodies/#{key}.gz"
        File.binwrite(file, gzip(content))
      elsif File.exist?(file)
        File.delete(file)
      end
      index = read_index(RECORD_DIR)
      index[key] = entry
      File.write(File.join(RECORD_DIR, "index.json"), Py.dumps(index, ensure_ascii: false, indent: 1, sort_keys: true) + "\n")
    end
  end

  def replay(method, url, body)
    @replay_index ||= read_index(REPLAY_DIR)
    entry = @replay_index[fixture_key(method, url, body)]
    unless entry
      raise ReplayMissing, "no recorded response in #{REPLAY_DIR} for #{method} #{url}" + (body ? " (body: #{body})" : "")
    end
    raise FetchError.new(entry["error"]["type"], entry["error"]["message"]) if entry.key?("error") # same type name and message as when recorded
    content = File.binread(File.join(REPLAY_DIR, entry["file"]))
    [entry["final_url"], entry["file"].end_with?(".gz") ? Zlib.gunzip(content) : content]
  end

  # Send one request (a POST if data is given) -> [final URL after redirects, body bytes].
  # Every network call goes through here, so that tests can record and replay them.
  def fetch(url, data = nil, headers = HEADERS, timeout = 30)
    method, body = data.nil? ? ["GET", nil] : ["POST", data.dup.force_encoding(Encoding::UTF_8)]
    return replay(method, url, body) if REPLAY_DIR
    begin
      final_url, content, status = request(method, url, data, headers, timeout)
    rescue StandardError => e
      if RECORD_DIR
        type = e.respond_to?(:py_type) ? e.py_type : e.class.name
        record(method, url, body, { "error" => { "type" => type, "message" => e.message } })
      end
      raise
    end
    record(method, url, body, { "status" => status, "final_url" => final_url }, content) if RECORD_DIR
    [final_url, content]
  end

  REDIRECTS = [301, 302, 303, 307, 308].freeze

  # One HTTP request with Net::HTTP: follows up to 10 redirects (a POST becomes a GET on
  # 301/302/303, and is not redirected on 307/308), raises on any non-2xx status, and turns
  # network errors into FetchError (see there for the names and messages).
  def request(method, url, data, headers, timeout)
    10.downto(0) do |redirects_left|
      uri = URI.parse(url)
      req = method == "POST" ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
      { "Accept-Encoding" => "identity", "Connection" => "close" }.merge(headers).each { |k, v| req[k] = v }
      if method == "POST"
        req["Content-Type"] ||= "application/x-www-form-urlencoded"
        req.body = data
      end
      # max_retries: 0, or Net::HTTP silently sends a GET again after a timeout or a reset
      # (doubling the wait and the load; the callers retry themselves). open_timeout covers
      # the TCP connection and the TLS handshake.
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", max_retries: 0,
                            open_timeout: timeout, read_timeout: timeout, write_timeout: timeout) { |http| http.request(req) }
      code = res.code.to_i
      followed = REDIRECTS.include?(code) && res["location"] && redirects_left.positive? &&
                 (method == "GET" || [301, 302, 303].include?(code))
      if followed
        url = URI.join(url, res["location"]).to_s
        method, data = "GET", nil
        next
      end
      raise FetchError.new("HTTPError", "HTTP Error #{code}: #{res.message}") unless (200..299).cover?(code)
      return [url, res.body.to_s.b, code]
    end
  rescue FetchError
    raise
  rescue Net::ReadTimeout, Net::WriteTimeout
    raise FetchError.new("TimeoutError", "The read operation timed out")
  rescue Net::OpenTimeout
    raise FetchError.new("URLError", "<urlopen error timed out>")
  rescue EOFError
    raise FetchError.new("RemoteDisconnected", "Remote end closed connection without response")
  rescue Errno::ECONNRESET => e
    raise FetchError.new("ConnectionResetError", "[Errno #{e.errno}] Connection reset by peer")
  rescue SystemCallError => e # "[Errno 111] Connection refused"
    raise FetchError.new("URLError", "<urlopen error [Errno #{e.errno}] #{e.class.new.message}>")
  rescue SocketError => e # DNS: "[Errno -2] Name or service not known"
    reason = e.message[/getaddrinfo\(3\): ([^)]*)/, 1] || e.message
    raise FetchError.new("URLError", "<urlopen error #{e.respond_to?(:error_code) ? "[Errno #{e.error_code}] " : ''}#{reason}>")
  rescue OpenSSL::SSL::SSLError, IOError => e
    raise FetchError.new("URLError", "<urlopen error #{e.message}>")
  end

  def get_url(url, retries = 3)
    with_retries(retries) do
      polite(url) { utf8(fetch(url)[1]) }
    end
  end

  # Up to `retries` attempts, 2 then 4 s apart.
  def with_retries(retries)
    retries.times do |attempt|
      return yield
    rescue StandardError
      raise if attempt == retries - 1
      pause(2 * (attempt + 1))
    end
  end

  # bytes.decode("utf-8", errors="replace")
  def utf8(bytes)
    bytes.dup.force_encoding(Encoding::UTF_8).scrub("�")
  end
end
