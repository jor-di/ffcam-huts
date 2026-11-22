#!/usr/bin/env bash
# Unit tests of the Ruby code (tests/unit/test_*.rb, minitest): the logic the replay scenarios
# of check.sh don't reach (dates, formats, booking rules, history, fetch log, politeness
# limiter, HTTP errors, command line). Offline (a local server at most), a few seconds.
#
#   tests/unit.sh                  # all tests
#   tests/unit.sh -n /polite/      # minitest options: only the tests whose name matches
set -euo pipefail
cd "$(dirname "$0")/.."
# real clock and politeness limiter: no test variable from the caller's environment
exec env -u FFCAM_NOW -u FFCAM_REPLAY_DIR -u FFCAM_RECORD_DIR \
  ruby -Irb -e 'Dir["tests/unit/test_*.rb"].sort.each { |f| require File.expand_path(f) }' -- "$@"
