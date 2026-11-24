# Refuge Pro: the calendar a hut embeds on its own site. Loaded by couchette.rb.

module Couchette
  REFUGEPRO_EMBED = "https://refuge-pro.com/embed/calendrier/%<slug>s"

  # Refuge Pro: the calendar a hut embeds on its site (refuge-pro.com/embed/calendrier/<slug>).
  # The page is a Next.js render whose payload holds availability.data = about a year of
  # {"date", "capacity", "booked", "free", "status": open|closed, "isFull", "unguarded"}, plus the
  # hut's rules. An open day with "unguarded": true (bookable, no keeper: winter room...) gets
  # UNGUARDED instead of OPEN (shown « Non gardé » on the map).
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
      out["opening"][day] = !is_open ? "CLOSE" : Py.truthy?(d["unguarded"]) ? "UNGUARDED" : "OPEN"
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
end
