# centrale.ffcam.fr: the FFCAM booking engine and its other portals. Loaded by ffcam.rb.
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

module Ffcam
  BASE_URL = "https://centrale.ffcam.fr/index.php"

  TYPES = {
    "BK_STRUCTURECATEGORY:REFUGE" => "refuge",
    "BK_STRUCTURECATEGORY:REFUGEHG_withBooking" => "refuge_non_garde",
    "BK_STRUCTURECATEGORY:CHALET" => "chalet",
    "BK_STRUCTURECATEGORY:CENTRE" => "centre",
  }.freeze

  def http(params, method = "GET", retries = 3)
    query = Py.urlencode(params)
    url, data = method == "GET" ? ["#{BASE_URL}?#{query}", nil] : ["#{BASE_URL}?", query]
    with_retries(retries) do
      polite(url) { utf8(fetch(url, data)[1]) }
    end
  end

  # Extract a `name = {...};` JSON literal from the page's inline JS.
  def js_var(html, name)
    m = html.match(/#{Regexp.escape(name)}\s*=\s*(.*?);\s*\n/)
    m && Py.loads(m[1])
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

  # Hut lists of the centrale portals, as compact hashes (first portal listing a hut wins).
  def fetch_centrale_huts(portals)
    structures = {}
    portals.each do |portal|
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
    end
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

  # Free beds / capacity / opening status / booking mode per day, for 2 months from date's month.
  def fetch_centrale_availability(hut_id, date, portal)
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
