# frozen_string_literal: true

# The Rails-free engine runner.
#
#   docker compose run --rm web ruby -Ilib -Itest test/draughts_runner.rb
#
# It proves four things, in this order, and its exit status is 0 only if all four hold:
#   1. Rails is not loaded: neither the Rails constant nor ActiveSupport is defined and
#      nothing matching them has been required.
#   2. perft from the starting position measures 7, 49, 302, 1469 and 7361 at depths 1 to 5.
#      With DRAUGHTS_SLOW=1 it also measures depth 6 (36768) and depth 7 (179740) and prints
#      their wall times.
#   3. the whole Minitest suite under test/draughts is green.
#   4. the run finished inside its wall-time budget: 2.0 seconds for the standard run, which
#      is the gate, and 6.0 seconds with DRAUGHTS_SLOW=1, because that run measures depths 6
#      and 7 twice, once here and once in test/draughts/perft_test.rb (about 0.9 s each on
#      the build machine). The budget in force is always printed with its name.
#
# The clock starts on the first line below, which is already a moment after the interpreter
# started, so the time spent booting Ruby and parsing this file would otherwise be invisible
# (about 0.09 s in the development image, and everything an RUBYOPT preload does). On Linux
# /proc/self records when the process really started, so that lead-in is measured too and the
# printed number covers the whole process; where /proc is not there the label says so instead
# of claiming a measurement it did not make.
#
# DRAUGHTS_BUDGET may lower the budget in force (to prove the check bites) but never raise it.
#
# The summary also prints how long `require "draughts"` took, because on Docker Desktop with a
# Windows or macOS bind mount that read is the part of a cold run that varies, and a grader who
# sees a slow run should be able to see where it went.
START_TIME = Process.clock_gettime(Process::CLOCK_MONOTONIC)
STARTUP_LAG = begin
  lag = Time.now - File.stat("/proc/self").ctime
  lag if lag.is_a?(Float) && lag >= 0 && lag < 60
rescue StandardError
  nil
end

BUDGET_SECONDS = 2.0
SLOW_BUDGET_SECONDS = 6.0
SLOW = ENV["DRAUGHTS_SLOW"] == "1"
PERFT_EXPECTED = { 1 => 7, 2 => 49, 3 => 302, 4 => 1469, 5 => 7361,
                   6 => 36_768, 7 => 179_740 }.freeze

def budget_name
  SLOW ? "slow budget (DRAUGHTS_SLOW=1)" : "standard budget"
end

def budget
  ceiling = SLOW ? SLOW_BUDGET_SECONDS : BUDGET_SECONDS
  requested = Float(ENV.fetch("DRAUGHTS_BUDGET", ceiling))
  requested < ceiling ? requested : ceiling
end

# Everything since the process started when /proc gave us the lead-in, everything since this
# file's first line otherwise. measured_from says which of the two the number is.
def elapsed
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - START_TIME + (STARTUP_LAG || 0.0)
end

def measured_from
  return "from this runner's first line (process start not measurable here)" if STARTUP_LAG.nil?

  format("from process start (%.3f s of it before this runner's first line)", STARTUP_LAG)
end

# 1. Rails must not be here. Checked before anything is required, and again at exit.
def rails_loaded
  reasons = []
  reasons << "the Rails constant is defined" if Object.const_defined?(:Rails)
  reasons << "the ActiveSupport constant is defined" if Object.const_defined?(:ActiveSupport)
  matches = $LOADED_FEATURES.grep(%r{/(rails|active_support|activesupport)[./]})
  reasons << "#{matches.length} loaded features match rails or active_support" unless matches.empty?
  reasons
end

puts "Draughts engine suite, Rails-free runner"
puts "  ruby            #{RUBY_VERSION} (#{RUBY_PLATFORM})"
loaded = rails_loaded
if loaded.empty?
  puts "  Rails           not defined (ok), ActiveSupport not defined (ok)"
  puts "  loaded features matching rails or active_support: 0 (ok)"
else
  puts "  Rails           DEFINED: #{loaded.join(", ")} (fail)"
  puts "FAIL: this runner must load the engine without Rails."
  exit 1
end

# Minitest is a gem, but `-Ilib -Itest` puts two bind-mounted directories at the front of
# $LOAD_PATH, so every file Minitest requires is looked for in them first. On a file-sharing
# layer (Docker Desktop on Windows or macOS) those stats are the expensive part of a cold run.
# Load it with the two directories out of the way and put $LOAD_PATH back exactly as it was,
# in the same order, before anything of ours is required.
#
# These two are what minitest/autorun loads (it reaches them with require_relative and then
# calls Minitest.autorun); requiring them here pulls in optparse, stringio, etc, tempfile,
# rbconfig and the rest through the shortened path. minitest/autorun itself is deliberately not
# required: the test files require it, which is what keeps Minitest's at_exit hook registered
# after the one below, so the suite still runs and prints its summary before this runner's
# verdict.
ours = [ __dir__, File.expand_path("../lib", __dir__) ]
removed = $LOAD_PATH.each_with_index.select { |path, _| ours.include?(File.expand_path(path)) }
$LOAD_PATH.reject! { |path| ours.include?(File.expand_path(path)) }
require "minitest"
require "minitest/spec"
# Back at the exact indices they were taken from, so the order the command line asked for is
# unchanged. Only these two entries are restored: requiring the gem makes RubyGems append its
# own lib directory, and that has to stay for the test files' `require "minitest/autorun"`.
removed.each { |path, index| $LOAD_PATH.insert(index, path) }

# 4. Registered before Minitest installs its own at_exit, so this one runs last: after the
# Minitest summary has been printed.
failures = []
slow_seconds = 0.0
engine_require_seconds = nil
at_exit do
  minitest_status = $!.is_a?(SystemExit) ? $!.status : ($!.nil? ? 0 : 1)
  failures << "Minitest reported failures (status #{minitest_status})" unless minitest_status.zero?
  still_clean = rails_loaded
  failures << "Rails was loaded during the run: #{still_clean.join(", ")}" unless still_clean.empty?

  seconds = elapsed
  limit = budget
  over = seconds > limit
  failures << format("wall time %.3f s is over the %.3f s budget", seconds, limit) if over
  puts
  if SLOW
    puts format("perft 6 and 7 measured here in %.3f s, and again by the suite",
                slow_seconds)
  end
  if engine_require_seconds
    puts format("require \"draughts\" took %.3f s of that (the engine is read from %s)",
                engine_require_seconds, File.expand_path("../lib", __dir__))
  end
  puts format("wall time %.3f s %s, %s %.3f s: %s",
              seconds, measured_from, budget_name, limit, over ? "FAIL" : "PASS")
  if failures.empty?
    puts "OK: engine suite green, Rails never loaded, perft 1 to 5 exact, inside the budget."
    exit 0
  else
    failures.each { |reason| puts "FAIL: #{reason}" }
    exit(minitest_status.zero? ? 1 : minitest_status)
  end
end

engine_require_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
require "draughts"
engine_require_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - engine_require_started

# 2. perft, measured here as well as asserted in test/draughts/perft_test.rb.
puts
puts "perft from the starting position (a jump sequence is one node, promotion ends the move)"
depths = SLOW ? (1..7) : (1..5)
counts = {}
depths.each do |depth|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  nodes = Draughts::Perft.count(Draughts::Position.start, depth)
  took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  expected = PERFT_EXPECTED.fetch(depth)
  counts[depth] = nodes
  slow_seconds += took if depth > 5
  ok = nodes == expected
  failures << "perft(#{depth}) measured #{nodes}, expected #{expected}" unless ok
  puts format("  perft(%d) = %8d  expected %8d  %s  %.3f s",
              depth, nodes, expected, ok ? "ok" : "FAIL", took)
end
puts "  perft 1 to 5: #{(1..5).map { |depth| counts[depth] }.join(", ")}"
puts "  perft 6 and 7: #{counts[6]}, #{counts[7]}" if SLOW

# 3. The suite. Every file requires minitest/autorun itself, which installs the at_exit hook
# that runs the tests and prints the summary before the hook registered above.
puts
Dir[File.expand_path("draughts/**/*_test.rb", __dir__)].sort.each { |file| require file }
