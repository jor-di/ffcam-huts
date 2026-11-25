# The hut list and the source of each hut. Loaded by couchette.rb.
#
# catalog/huts.json (bin/refresh-huts) gathers the huts of every source; the "portal" field of a hut
# says where its nights are read: a centrale portal (FFCAM, VANOISE...), OPENSYSTEM,
# REFUGEPRO, WPBS, or MANUAL (no online calendar: phone / mail).
# Refuge Pro (portal "REFUGEPRO") and WP Booking System (portal "WPBS"): huts listed by hand in
# catalog/manual/manual_huts.json, whose own calendar page is read (see fetch_refugepro_availability,
# fetch_wpbs_availability).

module Couchette
  HUTS_FILE = File.join(CATALOG_DIR, "huts.json")

  # Portals (apporigin) to collect huts from. Others exist:
  # ENTREPYRPYRENEES (Spanish/Andorran Pyrenees), ITFFCAM (all of them + Morocco).
  DEFAULT_PORTALS = %w[FFCAM VANOISE NEOUVIELLE BOREON OPENSYSTEM MANUAL].freeze

  # MANUAL: huts listed by hand in catalog/manual/manual_huts.json. Those with a "refugepro" slug book through
  # Refuge Pro (the hut's own booking software) and get availability (portal REFUGEPRO); those
  # with "wpbs" pages publish a WP Booking System calendar on their WordPress site (portal WPBS);
  # those with "opensystem" embed an Open System widget (portal OPENSYSTEM, id OPRF-<product id>),
  # with optional "guarded" seasons when the widget also sells the unguarded nights (see guarded_on?);
  # the others have no online booking we can read (phone / mail / form).
  MANUAL_HUTS_FILE = File.join(MANUAL_DIR, "manual_huts.json")

  # Normalize a hut name for matching: no accents, case, 'refuge/chalet/de/la...' or 'Non Gardé'.
  def norm(name)
    name = name.unicode_normalize(:nfkd).encode("US-ASCII", undef: :replace, invalid: :replace, replace: "").downcase
    name = name.gsub(/\(.*?\)|non garde/, " ")
    name = name.gsub(/\b(refuge|chalet|alpin|caf|du|de|des|la|le|les|l|d)\b/, " ")
    name.gsub(/[^a-z0-9]/, "")
  end

  # Fetch the hut lists of the given portals (first portal listing a hut wins).
  def fetch_huts(portals = DEFAULT_PORTALS)
    extra = portals.include?("OPENSYSTEM") ? fetch_opensystem_huts : []
    extra += manual_huts if portals.include?("MANUAL")
    fetch_centrale_huts(portals - %w[OPENSYSTEM MANUAL]) + extra
  end

  # Huts of catalog/manual/manual_huts.json, shaped like the others.
  def manual_huts(path = MANUAL_HUTS_FILE)
    return [] unless File.exist?(path)
    JSON.parse(File.read(path, encoding: "UTF-8"))["huts"].map do |h|
      h.merge("portal" => manual_portal(h), "email_user" => nil,
              "max_pax_per_booking" => nil, "max_nights" => nil, "booking_delay_days" => nil, "product_categories" => [])
    end
  end

  # Is `day` ("YYYY-MM-DD") in one of the keeper's seasons of a hut: [["MM-DD", "MM-DD"], ...], both ends
  # included; a season may run over the new year (["12-12", "03-28"]). See "guarded" in manual_huts.json.
  def guarded_on?(seasons, day)
    md = day[5..]
    seasons.any? { |from, to| from <= to ? from <= md && md <= to : md >= from || md <= to }
  end

  # Portal of a hut of catalog/manual/manual_huts.json: the calendar it publishes, if any.
  def manual_portal(hut)
    return "REFUGEPRO" if Py.truthy?(hut["refugepro"])
    return "WPBS" if Py.truthy?(hut["wpbs"])
    return "OPENSYSTEM" if Py.truthy?(hut["opensystem"]) # Open System widget outside the Vanoise park (id OPRF-<n>)
    "MANUAL"
  end

  def load_huts(path = HUTS_FILE)
    abort("#{path} not found: run bin/refresh-huts first.") unless File.exist?(path)
    JSON.parse(File.read(path, encoding: "UTF-8"))
  end

  # Free beds / capacity / opening status / booking mode per day, for 2 months from date's month.
  # `source`: the Refuge Pro slug (REFUGEPRO), the "wpbs" pages (WPBS), or the "guarded" season (OPENSYSTEM) of the hut.
  def fetch_availability(hut_id, date, portal = "FFCAM", source = nil)
    case portal
    when "REFUGEPRO" then fetch_refugepro_availability(source)
    when "WPBS" then fetch_wpbs_availability(source)
    when "MANUAL" then nil # no online availability: shown as "Sur demande"
    when "OPENSYSTEM" then fetch_opensystem_availability(hut_id, date, source)
    else fetch_centrale_availability(hut_id, date, portal)
    end
  end
end
