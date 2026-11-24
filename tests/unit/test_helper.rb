# Shared setup of the unit tests (run them with tests/unit.sh).
#
# The tests never touch the network nor the repository's data files: anything written goes
# to a temporary folder. They need the real clock and the politeness limiter, so
# COUCHETTE_NOW / COUCHETTE_REPLAY_DIR / COUCHETTE_RECORD_DIR must be unset (tests/unit.sh does it).

abort "unset COUCHETTE_NOW, COUCHETTE_REPLAY_DIR and COUCHETTE_RECORD_DIR to run the unit tests" if
  %w[COUCHETTE_NOW COUCHETTE_REPLAY_DIR COUCHETTE_RECORD_DIR].any? { |v| ENV[v] && !ENV[v].empty? }

require "minitest/autorun"
require "tmpdir"
LIB = File.expand_path("../../lib", __dir__)
BIN = File.expand_path("../../bin", __dir__)
require File.join(LIB, "couchette")
require File.join(LIB, "history")
require File.join(LIB, "fetch_log")
require File.join(LIB, "weekends")

# A page of the Refuge Pro calendar: the availability object inside Next.js flight chunks.
def refugepro_page(info)
  flight = %(1:["$","div",null,{"title":"Refuge \\"Z\\" é","availability":#{JSON.generate(info)}}]\n)
  escaped = JSON.generate(flight)[1...-1]
  chunks = escaped.scan(/(?:\\u\h{4}|\\.|[^\\]){1,30}/) # several pushes, escapes kept whole
  "<html>" + chunks.map { |c| %(<script>self.__next_f.push([1,"#{c}"])</script>) }.join + "</html>"
end
