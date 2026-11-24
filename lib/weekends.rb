# The nights shown on the map: this weekend (« dernière couchette ») and the next one
# (« avant-dernière »). Used by bin/fetch-availability.

require_relative "couchette"

module Couchette
  # Monday = 0 ... Sunday = 6
  def weekday(date)
    (date.wday + 6) % 7
  end

  # The Friday, Saturday and Sunday nights of the weekend shown on the map, not over yet.
  #
  # Mon-Fri: the coming Fri, Sat, Sun. Saturday: Sat (tonight), Sun. From Sunday on: the next
  # weekend (Fri, Sat, Sun), since on Sunday people plan for the coming one.
  def weekend_nights(today = nil)
    today ||= Couchette.local_today
    (0...3).map { |i| weekend_friday(today) + i }.select { |d| d >= today }
  end

  # Friday, Saturday and Sunday nights of the weekend after the current one (the map's
  # "avant-dernière couchette" mode). Always inside the fetched window (today -> end of next month).
  def next_weekend_nights(today = nil)
    today ||= Couchette.local_today
    (0...3).map { |i| weekend_friday(today) + 7 + i }
  end

  # Friday of the weekend shown on the map: this week's from Monday to Saturday,
  # the next one from Sunday on (on Sunday, people plan for the coming weekend).
  def weekend_friday(today)
    friday = today + (4 - weekday(today)) # Mon=0 ... Fri=4, Sat goes back to yesterday
    weekday(today) == 6 ? friday + 7 : friday # Sunday: jump to next Friday
  end
end
