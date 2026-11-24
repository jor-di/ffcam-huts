# Shared code of the scripts of bin/, in one module named after the site (« Dernière couchette »).
# This file holds what every script needs (paths, environment, command line, secrets, thread
# pool) and loads the rest:
#   clock.rb                  local time, fixed by COUCHETTE_NOW in tests
#   http.rb                   every request: politeness, retries, record / replay for tests
#   sources/ffcam_centrale.rb centrale.ffcam.fr (portals FFCAM, VANOISE, NEOUVIELLE, BOREON)
#   sources/open_system.rb    Open System (Vanoise park huts)
#   sources/refuge_pro.rb     Refuge Pro calendars (huts of manual_huts.json)
#   sources/wpbs.rb           WP Booking System calendars (huts of manual_huts.json)
#   sources.rb                the hut list (huts.json) and, per hut, the source to ask
#
# Each source returns a hut's nights as {"free", "capacity", "opening", "booking"}, each a
# {date => value} hash (see Couchette.fetch_availability).

require "date"
require "digest/sha1" # not just "digest": its lazy loading of SHA1 is not thread-safe on Ruby 3.2
require "fileutils"
require "json"
require "net/http"
require "openssl"
require "optparse"
require "uri"
require "zlib"
require_relative "py"

# Text is UTF-8 whatever the locale: a cron job often runs with LANG unset (C locale), where
# Ruby would read files as ASCII and tag the command line and environment as binary, and
# then fail on the first accent ("incompatible character encodings").
Encoding.default_external = Encoding::UTF_8
ARGV.map! { |arg| arg.dup.force_encoding(Encoding::UTF_8) }

module Couchette
  extend self

  # Data files live in the repository root, the parent of lib/ (and bin/).
  ROOT = File.expand_path("..", __dir__)

  SECRETS_FILE = File.join(ROOT, "secrets.env")

  # ---------- Tests: fixed clock, HTTP record / replay (see tests/README.md) ----------
  # COUCHETTE_NOW=2026-11-22T18:00:00    replaces "now" (local time) everywhere, and zeroes measured durations
  # COUCHETTE_RECORD_DIR=<dir>           real requests, each response (or failure) saved to <dir>
  # COUCHETTE_REPLAY_DIR=<dir>           no network: responses served from <dir>
  # An environment variable as UTF-8 text, nil when unset or empty.
  def env(name)
    value = ENV[name]&.dup&.force_encoding(Encoding::UTF_8)
    value unless value.nil? || value.empty?
  end

  # Run the block on each item with `workers` threads; results in input order. An exception
  # (any, ReplayMissing included) is raised again here, once all items ran: the first one in
  # input order.
  def pool_map(items, workers)
    raise ArgumentError, "workers must be at least 1 (got #{workers})" if workers < 1
    queue = Queue.new
    items.each_with_index { |item, i| queue << [item, i] }
    queue.close
    results = Array.new(items.size)
    errors = {}
    threads = Array.new([workers, items.size].min) do
      Thread.new do
        while (job = queue.pop)
          item, i = job
          begin
            results[i] = yield(item)
          rescue Exception => e # rubocop:disable Lint/RescueException
            errors[i] = e
          end
        end
      end
    end
    threads.each(&:join)
    raise errors[errors.keys.min] unless errors.empty?
    results
  end

  # Parse the command line (ARGV). Returns the positional arguments, at
  # most `positional` of them. A bad option, value or extra argument prints the error and the
  # usage on stderr and exits with status 2, without a stack trace.
  def parse_args(parser, positional: 0)
    rest = parser.parse(ARGV)
    raise OptionParser::NeedlessArgument, rest.drop(positional).join(" ") if rest.size > positional
    rest
  rescue OptionParser::ParseError => e
    usage_error(parser, e.message)
  end

  def usage_error(parser, message)
    warn parser.banner, "#{parser.program_name}: error: #{message}"
    exit 2
  end

  # An API key from the environment, else from secrets.env (KEY=value lines).
  def secret(name)
    return env(name) if env(name)
    return nil unless File.exist?(SECRETS_FILE)
    File.read(SECRETS_FILE, encoding: "UTF-8").each_line(chomp: true) do |line|
      key, sep, value = line.partition("=")
      return Py.either(value.strip, nil) if !sep.empty? && key.strip == name && !key.strip.start_with?("#")
    end
    nil
  end
end

require_relative "clock"
require_relative "http"
require_relative "sources/ffcam_centrale"
require_relative "sources/open_system"
require_relative "sources/refuge_pro"
require_relative "sources/wpbs"
require_relative "sources"
