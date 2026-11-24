# Open System (Alliance Réseaux). Loaded by ffcam.rb.
#
# Open System (portal "OPENSYSTEM"): 12 Vanoise national park huts (Leisse, Fond des Fours...)
# book through Open System / Alliance Réseaux, not the FFCAM centrale. Their sites (refuge-xxx.vanoise.com) embed
# a widget with a product id `ui:"OPRF-92948"`, whose planning is a public JSON(P) endpoint:
#   https://etape-rest.for-system.com/index.aspx/index.aspx?ref=json-planning-refuge&q=92948,<date>
# returning 30 days, from <date> - 15 days to <date> + 14 days: [{"s": free beds,
# "f": 1 if closed, "d": days *before* <date>}] (the day is <date> - d). No capacity is given.

module Ffcam
  # Open System huts are discovered from this site's "other huts" menu (all the park's huts)
  OPENSYSTEM_ENTRY = "https://refuge-leisse.vanoise.com/"
  OPENSYSTEM_PLANNING = "https://etape-rest.for-system.com/index.aspx/index.aspx?ref=json-planning-refuge&q=%<num>s,%<date>s"

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
end
