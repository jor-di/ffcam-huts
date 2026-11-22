# Shared helpers for the FFCAM booking site (centrale.ffcam.fr) and the other booking sources.
#
# How the FFCAM booking widget works (https://www.ffcam.fr/reserver-votre-refuge-en-ligne.html):
#   1. The page embeds an iframe served by centrale.ffcam.fr/index.php. That HTML
#      contains `structuresList = {...}`: every hut (id, name, type, ...).
#   2. Picking a hut POSTs `action=availability` to the same index.php. The HTML that
#      comes back contains, for two full months starting at the requested date's month:
#        BK.availability       {date: free beds}
#        BK.totalAvailability  {date: capacity}
#        BK.openingCalendar    {date: OPEN | CLOSE | UNGUARDED}
#
# The same server runs other booking portals, chosen with `apporigin`. Each portal lists its
# own huts (some shared with FFCAM), e.g. VANOISE adds the Vanoise national park huts.
# Availability must be requested through a portal that lists the hut.
#
# Open System (portal "OPENSYSTEM"): 12 Vanoise national park huts (Leisse, Fond des Fours...)
# book through Open System / Alliance Réseaux instead. Their sites (refuge-xxx.vanoise.com) embed
# a widget with a product id `ui:"OPRF-92948"`, whose planning is a public JSON(P) endpoint:
#   https://etape-rest.for-system.com/index.aspx/index.aspx?ref=json-planning-refuge&q=92948,<date>
# returning 30 days, from <date> - 15 days to <date> + 14 days: [{"s": free beds,
# "f": 1 if closed, "d": days *before* <date>}] (the day is <date> - d). No capacity is given.
#
# Refuge Pro (portal "REFUGEPRO") and WP Booking System (portal "WPBS"): huts listed by hand in
# manual_huts.json, whose own calendar page is read (see fetch_refugepro_availability,
# fetch_wpbs_availability).

require "date"
require "digest/sha1" # not just "digest": its lazy loading of SHA1 is not thread-safe on Ruby 3.2
require "fileutils"
require "json"
require "net/http"
require "openssl"
require "optparse"
require "uri"
require "zlib"
require_relative "py"

# Text is UTF-8 whatever the locale: a cron job often runs with LANG unset (C locale), where
# Ruby would read files as ASCII and tag the command line and environment as binary, and
# then fail on the first accent ("incompatible character encodings").
Encoding.default_external = Encoding::UTF_8
ARGV.map! { |arg| arg.dup.force_encoding(Encoding::UTF_8) }

module Ffcam
  extend self

  # Data files live in the repository root, the parent of rb/.
  ROOT = File.expand_path("..", __dir__)

  BASE_URL = "https://centrale.ffcam.fr/index.php"
  HEADERS = { "User-Agent" => "Mozilla/5.0 (X11; Linux x86_64) ffcam-huts-script" }.freeze
  HUTS_FILE = File.join(ROOT, "huts.json")
  # Portals (apporigin) to collect huts from. Others exist:
  # ENTREPYRPYRENEES (Spanish/Andorran Pyrenees), ITFFCAM (all of them + Morocco).
  DEFAULT_PORTALS = %w[FFCAM VANOISE NEOUVIELLE BOREON OPENSYSTEM MANUAL].freeze
  # MANUAL: huts listed by hand in manual_huts.json. Those with a "refugepro" slug book through
  # Refuge Pro (the hut's own booking software) and get availability (portal REFUGEPRO); those
  # with "wpbs" pages publish a WP Booking System calendar on their WordPress site (portal WPBS);
  # the others have no online booking we can read (phone / mail / form).
  MANUAL_HUTS_FILE = File.join(ROOT, "manual_huts.json")
  REFUGEPRO_EMBED = "https://refuge-pro.com/embed/calendrier/%<slug>s"
  # Open System huts are discovered from this site's "other huts" menu (all the park's huts)
  OPENSYSTEM_ENTRY = "https://refuge-leisse.vanoise.com/"
  OPENSYSTEM_PLANNING = "https://etape-rest.for-system.com/index.aspx/index.aspx?ref=json-planning-refuge&q=%<num>s,%<date>s"
  TYPES = {
    "BK_STRUCTURECATEGORY:REFUGE" => "refuge",
    "BK_STRUCTURECATEGORY:REFUGEHG_withBooking" => "refuge_non_garde",
    "BK_STRUCTURECATEGORY:CHALET" => "chalet",
    "BK_STRUCTURECATEGORY:CENTRE" => "centre",
  }.freeze

  SECRETS_FILE = File.join(ROOT, "secrets.env")

  # ---------- Tests: fixed clock, HTTP record / replay (see tests/README.md) ----------
  # FFCAM_NOW=2026-11-22T18:00:00    replaces "now" (local time) everywhere, and zeroes measured durations
  # FFCAM_RECORD_DIR=<dir>           real requests, each response (or failure) saved to <dir>
  # FFCAM_REPLAY_DIR=<dir>           no network: responses served from <dir>
  # An environment variable as UTF-8 text, nil when unset or empty.
  def env(name)
    value = ENV[name]&.dup&.force_encoding(Encoding::UTF_8)
    value unless value.nil? || value.empty?
  end

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

  # Run the block on each item with `workers` threads; results in input order. An exception
  # (any, ReplayMissing included) is raised again here, once all items ran: the first one in
  # input order.
  def pool_map(items, workers)
    raise ArgumentError, "workers must be at least 1 (got #{workers})" if workers < 1
    queue = Queue.new
    items.each_with_index { |item, i| queue << [item, i] }
    queue.close
    results = Array.new(items.size)
    errors = {}
    threads = Array.new([workers, items.size].min) do
      Thread.new do
        while (job = queue.pop)
          item, i = job
          begin
            results[i] = yield(item)
          rescue Exception => e # rubocop:disable Lint/RescueException
            errors[i] = e
          end
        end
      end
    end
    threads.each(&:join)
    raise errors[errors.keys.min] unless errors.empty?
    results
  end

  # Parse the command line (ARGV). Returns the positional arguments, at
  # most `positional` of them. A bad option, value or extra argument prints the error and the
  # usage on stderr and exits with status 2, without a stack trace.
  def parse_args(parser, positional: 0)
    rest = parser.parse(ARGV)
    raise OptionParser::NeedlessArgument, rest.drop(positional).join(" ") if rest.size > positional
    rest
  rescue OptionParser::ParseError => e
    usage_error(parser, e.message)
  end

  def usage_error(parser, message)
    warn parser.banner, "#{parser.program_name}: error: #{message}"
    exit 2
  end

  # An API key from the environment, else from secrets.env (KEY=value lines).
  def secret(name)
    return env(name) if env(name)
    return nil unless File.exist?(SECRETS_FILE)
    File.read(SECRETS_FILE, encoding: "UTF-8").each_line(chomp: true) do |line|
      key, sep, value = line.partition("=")
      return Py.either(value.strip, nil) if !sep.empty? && key.strip == name && !key.strip.start_with?("#")
    end
    nil
  end

  # Now, as local time; fixed by FFCAM_NOW.
  def local_now
    fixed = env("FFCAM_NOW")
    return Time.now unless fixed
    m = fixed.match(/\A(\d{4})-(\d\d)-(\d\d)(?:[T ](\d\d):(\d\d)(?::(\d\d)(?:\.\d+)?)?)?\z/) or
      abort("FFCAM_NOW: invalid isoformat string: '#{fixed}'")
    # a UTC Time used as a plain wall-clock time: Time.new (local) would move a time that
    # doesn't exist locally (2026-03-29T02:30 in Paris, DST gap) to 03:30
    Time.utc(*m.captures.map(&:to_i))
  end

  def local_today
    local_now.to_date
  end

  # isoformat(timespec="seconds") of a local time
  def isoformat(time)
    time.strftime("%Y-%m-%dT%H:%M:%S")
  end

  def clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # time.monotonic(), frozen at 0 with FFCAM_NOW so that measured durations are 0 (stable test outputs).
  def monotonic
    env("FFCAM_NOW") ? 0.0 : clock
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

  def http(params, method = "GET", retries = 3)
    query = Py.urlencode(params)
    url, data = method == "GET" ? ["#{BASE_URL}?#{query}", nil] : ["#{BASE_URL}?", query]
    with_retries(retries) do
      polite(url) { utf8(fetch(url, data)[1]) }
    end
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

  # Extract a `name = {...};` JSON literal from the page's inline JS.
  def js_var(html, name)
    m = html.match(/#{Regexp.escape(name)}\s*=\s*(.*?);\s*\n/)
    m && Py.loads(m[1])
  end

  # Normalize a hut name for matching: no accents, case, 'refuge/chalet/de/la...' or 'Non Gardé'.
  def norm(name)
    name = name.unicode_normalize(:nfkd).encode("US-ASCII", undef: :replace, invalid: :replace, replace: "").downcase
    name = name.gsub(/\(.*?\)|non garde/, " ")
    name = name.gsub(/\b(refuge|chalet|alpin|caf|du|de|des|la|le|les|l|d)\b/, " ")
    name.gsub(/[^a-z0-9]/, "")
  end

  # Return https://<subdomain>.ffcam.fr/ if that hut website exists (unknown ones redirect to www.ffcam.fr).
  def hut_site(subdomain)
    return nil unless subdomain.to_s.match?(/\A[a-z0-9-]+\z/)
    url = "https://#{subdomain}.ffcam.fr/"
    polite(url) { fetch(url, nil, HEADERS, 20)[0].start_with?(url) ? url : nil }
  rescue StandardError
    nil
  end

  # Emails are obfuscated as `name<a></a><ff></ff><d></d><fr></fr>`: keep the part before @.
  # It usually equals the hut's website subdomain (name.ffcam.fr), handy to match OSM data.
  def email_user(raw)
    user = Py.either(raw, "").partition("<a></a>")[0].gsub("<d></d>", ".")
    Py.either(user.gsub(/<[^>]*>/, ""), nil)
  end

  # Vanoise park huts booked through Open System: id OPRF-<n>, name, site.
  def fetch_opensystem_huts(entry = OPENSYSTEM_ENTRY)
    page = get_url(entry)
    sites = page.scan(%r{href="(https://refuge-[a-z-]+\.vanoise\.com)/?"[^>]*>\s*([^<]+?)\s*<})
                .to_h { |u, n| [u.sub(%r{/+\z}, ""), Py.strip(Py.html_unescape(n))] }
    # the entry hut is not in its own menu: take its name from the page title ("Accueil | Refuge de la Leisse")
    title = page.match(%r{<title>([^<]+)</title>})
    parts = title ? Py.html_unescape(title[1]).split("|", -1).map { |t| Py.strip(t) } : [entry]
    sites[entry.sub(%r{/+\z}, "")] ||= parts.find { |t| t.downcase.start_with?("refuge") } || parts[-1]
    sites.sort.filter_map do |site, name|
      html = get_url("#{site}/")
      m = html.match(/ui:"OPRF-(\d+)"/)
      next unless m # this hut books through the FFCAM centrale (VANOISE portal) instead
      {
        "id" => "OPRF-#{m[1]}", "portal" => "OPENSYSTEM", "name" => name,
        "short_name" => name.sub(/\ARefuge (de la |de l'|du |des |de |d')/, ""),
        "type" => "refuge", "email_user" => nil, "site" => "#{site}/",
        "max_pax_per_booking" => nil, "max_nights" => nil, "booking_delay_days" => nil, "product_categories" => [],
      }
    end
  end

  # Fetch the hut lists of the given portals, as compact hashes (first portal listing a hut wins).
  def fetch_huts(portals = DEFAULT_PORTALS)
    structures = {}
    extra = portals.include?("OPENSYSTEM") ? fetch_opensystem_huts : []
    if portals.include?("MANUAL") && File.exist?(MANUAL_HUTS_FILE)
      JSON.parse(File.read(MANUAL_HUTS_FILE, encoding: "UTF-8"))["huts"].each do |h|
        extra << h.merge("portal" => manual_portal(h), "email_user" => nil,
                         "max_pax_per_booking" => nil, "max_nights" => nil, "booking_delay_days" => nil, "product_categories" => [])
      end
    end
    (portals - %w[OPENSYSTEM MANUAL]).each do |portal|
      html = http({ "mode" => "FORM", "_lang" => "FR", "init" => 1, "apporigin" => portal })
      found = js_var(html, "structuresList")
      raise "Could not find the hut list (structuresList) of portal #{portal}." unless Py.truthy?(found)
      found.each { |hut_id, s| structures[hut_id] ||= [portal, s] }
    end
    structures.map do |hut_id, (portal, s)|
      {
        "id" => hut_id,
        "portal" => portal,
        "name" => Py.strip(Py.html_unescape(s.fetch("name", ""))),
        "short_name" => Py.strip(Py.html_unescape(s.fetch("shortName", ""))),
        "type" => TYPES.fetch(s["structureType"], s["structureType"]),
        "email_user" => email_user(s["email"]),
        "max_pax_per_booking" => s["maxPax"],
        "max_nights" => s["maxDays"],
        "booking_delay_days" => s["bookingDelay"],
        "product_categories" => s.fetch("productsCategories", []).map { |p| p["oid"] },
      }
    end + extra
  end

  # Portal of a hut of manual_huts.json: the calendar it publishes, if any.
  def manual_portal(hut)
    return "REFUGEPRO" if Py.truthy?(hut["refugepro"])
    return "WPBS" if Py.truthy?(hut["wpbs"])
    "MANUAL"
  end

  def load_huts(path = HUTS_FILE)
    abort("#{path} not found: run rb/refresh_huts.rb first.") unless File.exist?(path)
    JSON.parse(File.read(path, encoding: "UTF-8"))
  end

  # Open System planning: 30 days from `date` (capacity unknown, so nil).
  def fetch_opensystem_availability(hut_id, date)
    query = date + 15 # the answer covers query-15 .. query+14
    text = get_url(format(OPENSYSTEM_PLANNING, num: hut_id.split("-", 2)[1], date: query.iso8601))
    first, last = text.index("("), text.rindex(")") # callback({json})
    raise "no JSONP payload in the Open System planning of #{hut_id}" unless first && last && first < last
    data = Py.loads(text[(first + 1)...last])
    out = { "free" => {}, "capacity" => {}, "opening" => {} }
    (Py.truthy?(data) ? data[0]["planning"] : []).each do |e|
      day = (query - e["d"]).iso8601
      out["free"][day] = e["s"]
      out["capacity"][day] = nil
      out["opening"][day] = Py.truthy?(e["f"]) ? "CLOSE" : "OPEN"
    end
    out
  end

  # How a night can be booked, read from the classes of each day of the FFCAM calendar:
  #   "day dispo"                      -> online
  #   "day complet waitinglistday"     -> waitlist (full, waiting list open)
  #   "day completWeb completWebInfo"  -> phone (no longer sold online: "Réserver par téléphone / mail")
  BOOKING_CLASSES = [%w[waitinglistday waitlist], %w[completWeb phone], %w[dispo online]].freeze

  def booking_modes(html)
    modes = {}
    html.scan(/<div class="(day[^"]*)">\s*<a [^>]*data-date="(\d{4}-\d{2}-\d{2})"/) do |classes, day|
      tokens = classes.split
      found = BOOKING_CLASSES.find { |token, _| tokens.include?(token) }
      modes[day] = found[1] if found
    end
    modes
  end

  # Refuge Pro: the calendar a hut embeds on its site (refuge-pro.com/embed/calendrier/<slug>).
  # The page is a Next.js render whose payload holds availability.data = about a year of
  # {"date", "capacity", "booked", "free", "status": open|closed, "isFull"}, plus the hut's rules.
  def fetch_refugepro_availability(slug, today = nil)
    page = get_url(format(REFUGEPRO_EMBED, slug: slug))
    chunks = page.scan(/self\.__next_f\.push\(\[1,"((?:[^"\\]++|\\.)*+)"\]\)/).map(&:first)
    flight = chunks.map { |c| Py.loads("\"#{c}\"") }.join
    start = flight.index('"availability":{')
    raise "no availability in the Refuge Pro calendar of #{slug}" unless start
    # the availability object is plain JSON: read it from its first brace
    info = Py.raw_decode(flight, start + '"availability":'.size)
    today ||= local_today
    cutoff = (today + Py.either(info["bookingCutoffDays"], 0)).iso8601
    season = Py.either(info["nextSeasonOpening"], {})
    not_yet = Py.truthy?(season["ouvreLe"]) && today.iso8601 < season["ouvreLe"]
    out = { "free" => {}, "capacity" => {}, "opening" => {}, "booking" => {} }
    info.fetch("data", []).each do |d|
      day, is_open = d["date"], d["status"] == "open"
      out["free"][day], out["capacity"][day] = d["free"], d["capacity"]
      out["opening"][day] = is_open ? "OPEN" : "CLOSE"
      next unless is_open
      if Py.truthy?(d["isFull"]) || !Py.truthy?(d["free"])
        out["booking"][day] = Py.truthy?(info["waitlistEnabled"]) ? "waitlist" : nil
      elsif day < cutoff || (not_yet && day >= season.fetch("premiereNuit", "9999"))
        out["booking"][day] = "phone" # not (or no longer) open to online booking
        out["free"][day] = 0
      else
        out["booking"][day] = "online"
      end
    end
    out
  end

  # ---------- WP Booking System (WordPress plugin "wp-booking-system-premium") ----------
  # The calendar is rendered server-side in the page: one container per calendar
  #   <div class="wpbs-container ... wpbs-calendar-12 " data-id="12" data-current_year="2026"
  #        data-current_month="11" data-changeover_start="58" data-changeover_end="59" ...>
  # holding the shown months (data-months_to_show, the current one first), one element per day
  #   <div class="wpbs-date wpbs-legend-item-66 wpbs-is-bookable " data-year="2026" data-month="11"
  #        data-day="28" ...> ... <span class="wpbs-inventory">1 pl.</span> ...
  # (wpbs-legend-item-<n> = the day's status, wpbs-is-bookable when it can be selected, the
  # inventory = places left, or <span class="wpbs-inventory wpbs-full">Complet</span>), and the
  # legend naming each status (ids differ per site and calendar):
  #   <div class="wpbs-legend-item"><div class="wpbs-legend-item-icon wpbs-legend-item-icon-66" ...>
  #   ...<span class=wpbs-legend-item-name>Disponible (non-gardé)</span></div>
  # Other months are loaded by the site through admin-ajax.php: not used, only the months in the
  # page are read. No capacity is given (nil).

  # Meaning of a legend name: available / full / closed (nil: unknown, decided by the bookable flag).
  def wpbs_meaning(name)
    plain = name.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase
    return :closed if plain.match?(/non[- ]?disponible|indisponible|ferme|closed|unavailable|voir/)
    return :full if plain.match?(/complet|full|booked/)
    return :available if plain.match?(/disponible|libre|available/)
    nil
  end

  # Parse the WP Booking System calendars of a page -> {"free", "capacity", "opening", "booking"}
  # for the days from `today` on. `calendars`: only these calendar ids (default: all of the page;
  # a day shown by several calendars is taken from the first one).
  # Rules, in this order (days before `today` skipped):
  #   inventory "Complet" or "0 pl."             -> OPEN, 0 free, no booking mode (full)
  #   status "closed" (Non-disponible, Voir refuge été...)  -> CLOSE
  #   bookable (wpbs-is-bookable), inventory "N pl."        -> OPEN, N free, online
  #   status "full" (legend "Complet", changeover start)    -> OPEN, 0 free (full)
  #   not bookable                               -> CLOSE
  #   bookable, no inventory shown               -> OPEN, places unknown (nil), request ("Sur demande")
  # A status absent from the legend: changeover end = available; others decided by the bookable flag.
  def parse_wpbs(html, url, today = nil, calendars: nil)
    today = (today || local_today).iso8601
    starts = html.enum_for(:scan, /<div class="wpbs-container\s[^"]*"([^>]*)>/).map { Regexp.last_match }
    raise "no WP Booking System calendar on #{url}" if starts.empty?
    out = { "free" => {}, "capacity" => {}, "opening" => {}, "booking" => {} }
    days = 0
    starts.each_with_index do |start, i|
      attrs = start[1].scan(/data-([a-z_]+)="([^"]*)"/).to_h
      next if calendars && !calendars.map(&:to_s).include?(attrs["id"])
      section = html[start.begin(0)...(starts[i + 1]&.begin(0) || html.size)]
      legend = section.scan(/<div class="wpbs-legend-item">\s*<div class="wpbs-legend-item-icon wpbs-legend-item-icon-(\d+)".*?wpbs-legend-item-name"?>([^<]*)</m)
                      .to_h { |id, name| [id, wpbs_meaning(Py.html_unescape(name))] }
      legend[attrs["changeover_start"]] = :full if Py.truthy?(attrs["changeover_start"])
      legend[attrs["changeover_end"]] ||= :available if Py.truthy?(attrs["changeover_end"]) # the night after a departure
      tags = section.enum_for(:scan, /<div class="(wpbs-date\s[^"]*)"([^>]*)>/).map { Regexp.last_match }
      tags.each_with_index do |tag, j|
        ymd = %w[year month day].map { |k| tag[2][/data-#{k}="(\d+)"/, 1]&.to_i }
        next unless ymd.all? && Date.valid_date?(*ymd) # padding cells (wpbs-gap) have no date
        day = Date.new(*ymd).iso8601
        days += 1
        next if day < today || out["opening"].key?(day)
        classes = tag[1].split
        body = section[tag.end(0)...(tags[j + 1]&.begin(0) || section.size)]
        inventory = body.match(/<span class="wpbs-inventory([^"]*)">([^<]*)</)
        free = if inventory.nil? then nil
               elsif inventory[1].split.include?("wpbs-full") || !inventory[2].match?(/\d/) then 0
               else inventory[2][/\d+/].to_i
               end
        meaning = legend[classes.find { |c| c.start_with?("wpbs-legend-item-") }&.delete_prefix("wpbs-legend-item-")]
        out["capacity"][day] = nil
        bookable = classes.include?("wpbs-is-bookable")
        out["opening"][day], out["free"][day], out["booking"][day] =
          if free&.zero? then ["OPEN", 0, nil]                     # inventory "Complet" / 0 pl.
          elsif meaning == :closed then ["CLOSE", nil, nil]
          elsif bookable && free then ["OPEN", free, "online"]     # places left: the inventory wins
          elsif meaning == :full then ["OPEN", 0, nil]
          elsif !bookable then ["CLOSE", nil, nil]
          else ["OPEN", nil, "request"]                            # bookable, places not shown
          end
      end
    end
    raise "no day in the WP Booking System calendar of #{url}" if days.zero?
    out
  end

  # WP Booking System calendars of a hut: `pages` = [{"url" => page, "calendars" => [ids] (optional)}]
  # (manual_huts.json "wpbs"); a day found on several pages is taken from the first one.
  def fetch_wpbs_availability(pages, today = nil)
    out = { "free" => {}, "capacity" => {}, "opening" => {}, "booking" => {} }
    Array(pages).each do |page|
      page = { "url" => page } if page.is_a?(String)
      found = parse_wpbs(get_url(page["url"]), page["url"], today, calendars: page["calendars"])
      (found["opening"].keys - out["opening"].keys).each do |day|
        out.each_key { |field| out[field][day] = found[field][day] }
      end
    end
    out
  end

  # Free beds / capacity / opening status / booking mode per day, for 2 months from date's month.
  # `source`: the Refuge Pro slug (REFUGEPRO) or the "wpbs" pages (WPBS) of the hut.
  def fetch_availability(hut_id, date, portal = "FFCAM", source = nil)
    return fetch_refugepro_availability(source) if portal == "REFUGEPRO"
    return fetch_wpbs_availability(source) if portal == "WPBS"
    return nil if portal == "MANUAL" # no online availability: shown as "Sur demande"
    return fetch_opensystem_availability(hut_id, date) if portal == "OPENSYSTEM"
    html = http(
      {
        "action" => "availability",
        "apporigin" => portal,
        "structure" => hut_id,
        "productCategory" => "nomatter", # all accommodation types together
        "pax" => 1,
        "date" => date.iso8601,
      },
      "POST",
    )
    {
      "free" => Py.either(js_var(html, "BK.availability"), {}),
      "capacity" => Py.either(js_var(html, "BK.totalAvailability"), {}),
      "opening" => Py.either(js_var(html, "BK.openingCalendar"), {}),
      "booking" => booking_modes(html),
    }
  end
end
