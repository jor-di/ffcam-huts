# Shared setup of the unit tests (run them with tests/unit.sh).
#
# The tests never touch the network nor the repository's data files: anything written goes
# to a temporary folder. They need the real clock and the politeness limiter, so
# FFCAM_NOW / FFCAM_REPLAY_DIR / FFCAM_RECORD_DIR must be unset (tests/unit.sh does it).

abort "unset FFCAM_NOW, FFCAM_REPLAY_DIR and FFCAM_RECORD_DIR to run the unit tests" if
  %w[FFCAM_NOW FFCAM_REPLAY_DIR FFCAM_RECORD_DIR].any? { |v| ENV[v] && !ENV[v].empty? }

require "minitest/autorun"
require "tmpdir"
RB = File.expand_path("../../rb", __dir__)
require File.join(RB, "ffcam")
require File.join(RB, "history")
require File.join(RB, "fetch_log")
# the scripts define their helpers as top-level methods; `main` only runs when executed
load File.join(RB, "ffcam_availability.rb")

# A page of the Refuge Pro calendar: the availability object inside Next.js flight chunks.
def refugepro_page(info)
  flight = %(1:["$","div",null,{"title":"Refuge \\"Z\\" é","availability":#{JSON.generate(info)}}]\n)
  escaped = JSON.generate(flight)[1...-1]
  chunks = escaped.scan(/(?:\\u\h{4}|\\.|[^\\]){1,30}/) # several pushes, escapes kept whole
  "<html>" + chunks.map { |c| %(<script>self.__next_f.push([1,"#{c}"])</script>) }.join + "</html>"
end
