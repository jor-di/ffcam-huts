# WP Booking System: a calendar in a WordPress page of the hut's site. Loaded by couchette.rb.

module Couchette
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
    return :unguarded if plain.match?(/disponible|libre|available/) && plain.match?(/non[- ]?garde|unguarded/)
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
  # A bookable day whose status is « Disponible (non-gardé) » gets UNGUARDED instead of OPEN (the
  # map shows it « Non gardé », with its places).
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
        open = meaning == :unguarded ? "UNGUARDED" : "OPEN" # « Disponible (non-gardé) »: bookable, no keeper
        out["opening"][day], out["free"][day], out["booking"][day] =
          if free&.zero? then ["OPEN", 0, nil]                     # inventory "Complet" / 0 pl.
          elsif meaning == :closed then ["CLOSE", nil, nil]
          elsif bookable && free then [open, free, "online"]       # places left: the inventory wins
          elsif meaning == :full then ["OPEN", 0, nil]
          elsif !bookable then ["CLOSE", nil, nil]
          else [open, nil, "request"]                              # bookable, places not shown
          end
      end
    end
    raise "no day in the WP Booking System calendar of #{url}" if days.zero?
    out
  end

  # WP Booking System calendars of a hut: `pages` = [{"url" => page, "calendars" => [ids] (optional)}]
  # (catalog/manual/manual_huts.json "wpbs"); a day found on several pages is taken from the first one.
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
end
