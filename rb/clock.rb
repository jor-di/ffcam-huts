# Local time (Paris), fixed by FFCAM_NOW in tests (see tests/README.md). Loaded by ffcam.rb.

module Ffcam
  # Now, as local time; fixed by FFCAM_NOW.
  def local_now
    fixed = env("FFCAM_NOW")
    return Time.now unless fixed
    m = fixed.match(/\A(\d{4})-(\d\d)-(\d\d)(?:[T ](\d\d):(\d\d)(?::(\d\d)(?:\.\d+)?)?)?\z/) or
      abort("FFCAM_NOW: invalid isoformat string: '#{fixed}'")
    # a UTC Time used as a plain wall-clock time: Time.new (local) would move a time that
    # doesn't exist locally (2026-03-29T02:30 in Paris, DST gap) to 03:30
    Time.utc(*m.captures.map(&:to_i))
  end

  def local_today
    local_now.to_date
  end

  # isoformat(timespec="seconds") of a local time
  def isoformat(time)
    time.strftime("%Y-%m-%dT%H:%M:%S")
  end

  def clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # time.monotonic(), frozen at 0 with FFCAM_NOW so that measured durations are 0 (stable test outputs).
  def monotonic
    env("FFCAM_NOW") ? 0.0 : clock
  end
end
