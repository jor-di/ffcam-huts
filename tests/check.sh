#!/usr/bin/env bash
# Replay the recorded scenarios (tests/fixtures/) with the Ruby scripts (rb/), offline and with
# a fixed clock, and compare every output file with tests/golden/, byte for byte.
#
#   tests/check.sh            # ("tests/check.sh ruby" works too)
#   tests/check.sh --keep     # keep the work folders (path printed at the end)
#   tests/check.sh --update   # rewrite tests/golden/ from this run (after a re-recording)
#
# Exit status: 0 if every output matches, 1 otherwise. See tests/README.md.
set -uo pipefail

# ---------- Adjust here ----------
# How to run one script (%s = script name, without extension).
RUN="rb/%s.rb"
# Code copied into the work folder (relative to the repo root). The scripts read / write their
# data files in the parent of rb/, i.e. the work folder.
CODE="rb .ruby-version"
# Files every scenario starts with (relative to the repo root).
INPUTS="manual_huts.json coordinates_overrides.json map_template.html log_template.html"
# Scenarios: fixed clock, then the scripts in order (a step may carry arguments: "build_map x.csv").
RUN1_NOW=2026-11-22T18:00:00
RUN1_STEPS=(refresh_huts refresh_coordinates refresh_links "ffcam_availability --history" build_map)
# run2 starts from run1's golden outputs (hut lists and history/)
RUN2_NOW=2026-11-23T09:00:00
RUN2_FROM_RUN1="huts.json hut_coordinates.json hut_links.json history"
RUN2_STEPS=("ffcam_availability --history" build_map)
# Files written by the scripts that are not outputs to compare (regex on the relative path).
IGNORE='(^|/)\.bundle(/|$)'
# ----------------------------------

REPO=$(cd "$(dirname "$0")/.." && pwd)
TESTS=$REPO/tests
impl=ruby
keep=0 update=0
for a in "$@"; do
  case $a in
    ruby) ;; # the only implementation since the Python one was removed; still accepted
    --keep) keep=1 ;;
    --update) update=1 ;;
    *) echo "usage: tests/check.sh [--keep] [--update]" >&2; exit 2 ;;
  esac
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ffcam-check.XXXXXX")
if (( keep )); then trap 'echo "work folders kept in $TMP"' EXIT; else trap 'rm -rf "$TMP"' EXIT; fi
failures=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

# Relative path + sha1 of every file of a folder (to spot what the scripts wrote).
snapshot() { (cd "$1" && find . -type f -printf '%P\n' | grep -Ev "$IGNORE" | xargs -r -d '\n' sha1sum | LC_ALL=C sort); }

run_scenario() {
  local name=$1 now=$2; shift 2
  local work=$TMP/$name logs=$TMP/$name-stderr golden=$TESTS/golden/$name
  echo "== $name ($impl, FFCAM_NOW=$now)"
  mkdir -p "$work" "$logs"
  (cd "$REPO" && cp -r $CODE $INPUTS "$work/") || { fail "copy of code and inputs"; return; }
  if [[ $name == run2 ]]; then
    for f in $RUN2_FROM_RUN1; do cp -r "$TESTS/golden/run1/$f" "$work/"; done
  fi
  local before; before=$(snapshot "$work")

  for step in "$@"; do
    local script=${step%% *} args=""
    [[ $step == *" "* ]] && args=${step#* }
    local cmd; cmd=$(printf "$RUN" "$script")
    # offline, fixed clock, no secret / CI variable from the caller's environment
    (cd "$work" && env -u GITHUB_EVENT_NAME -u TRIGGER_SOURCE -u IGN_API_KEY -u FFCAM_RECORD_DIR \
        FFCAM_REPLAY_DIR="$TESTS/fixtures/$name" FFCAM_NOW="$now" TZ=Europe/Paris \
        SKITOUR_API_KEY=replay-dummy-key $cmd $args) 2> "$logs/$script.raw" > /dev/null
    local status=$?
    sed "s|$work|<work>|g" "$logs/$script.raw" > "$logs/$script.log" && rm "$logs/$script.raw"
    if (( status )); then
      fail "$script exited with status $status:"
      tail -n 5 "$logs/$script.log" | sed 's/^/        /'
    fi
  done

  # outputs = files created or changed by the scripts
  local outputs; outputs=$(comm -13 <(echo "$before") <(snapshot "$work") | cut -c43- | LC_ALL=C sort -u)

  if (( update )); then
    rm -rf "$golden" && mkdir -p "$golden/stderr"
    while read -r f; do [[ -n $f ]] && mkdir -p "$golden/$(dirname "$f")" && cp "$work/$f" "$golden/$f"; done <<< "$outputs"
    cp "$logs"/*.log "$golden/stderr/"
    echo "  golden updated: $(echo "$outputs" | grep -c .) files in ${golden#$REPO/}"
    return
  fi

  local expected; expected=$(cd "$golden" && find . -type f -printf '%P\n' | grep -v '^stderr/' | LC_ALL=C sort)
  while read -r f; do
    [[ -z $f ]] && continue
    if [[ ! -f $work/$f ]]; then
      fail "$f (not written)"
    elif diff -u --label "golden/$name/$f" --label "$impl/$name/$f" "$golden/$f" "$work/$f" > "$TMP/diff"; then
      pass "$f"
    else
      fail "$f"
      head -n 40 "$TMP/diff" | sed 's/^/        /'
    fi
  done <<< "$expected"
  for f in $(comm -13 <(echo "$expected") <(echo "$outputs")); do fail "$f (unexpected output, not in golden)"; done
  # stderr: for reference only (wording of the summary lines may change)
  for log in "$golden"/stderr/*.log; do
    local mine=$logs/$(basename "$log")
    if cmp -s "$log" "$mine"; then echo "  info  stderr of $(basename "$log" .log): same"
    else echo "  info  stderr of $(basename "$log" .log): differs (not a failure; diff -u $log $mine)"; fi
  done
}

run_scenario run1 "$RUN1_NOW" "${RUN1_STEPS[@]}"
run_scenario run2 "$RUN2_NOW" "${RUN2_STEPS[@]}"

if (( update )); then exit 0; fi
if (( failures )); then echo "FAIL: $failures difference(s)"; exit 1; fi
echo "PASS: all outputs identical to tests/golden"
