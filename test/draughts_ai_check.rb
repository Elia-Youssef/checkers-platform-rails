# frozen_string_literal: true

# The slow AI check: strength and timing, which are too expensive for the fast engine suite.
#
#   docker compose run --rm web ruby -Ilib -Itest test/draughts_ai_check.rb
#
# Like test/draughts_runner.rb it loads no Rails and needs no gems. It is the evidence for
# two rubric items:
#
#   item 9   Medium wins at least 8 of 10 games against Easy, 5 as Red and 5 as White,
#            played through Draughts::Game with the draw rules active
#   item 10  a Hard move completes in 3.0 seconds or less while the search reports reaching
#            depth 8 or more, from the start and from a mid-game position
#
# The depth bar and the time limit below are written as literals, so that moving a constant
# in lib/draughts/ai.rb cannot move the bar that is supposed to police it.
#
# Sections, and what makes the exit status non-zero:
#
#   1  strength   ten Medium against Easy games       fails under 8 Medium wins
#   2  timing     four positions, twice, without and with YJIT
#                                                     fails on depth under 8 or over 3.0 s
#   3  table      the transposition table must change neither a score nor a move
#                                                     fails on any disagreement
#   4  Hard against Medium, informational and never graded, only when DRAUGHTS_AI_HARD holds
#      a game count. CONCEPT.md 6.2 expects Hard not to lose to Medium. It is behind the
#      flag because every game is a minute or more of real search.
#
# YJIT: Rails 8.1 turns YJIT on through config.load_defaults 8.1 only outside development
# and test (railties sets config.yjit = !Rails.env.local?), so the development container
# this is measured in runs without it. Section 2 therefore reports both, first as the
# process was launched and then after calling RubyVM::YJIT.enable, and the pass or fail
# applies to both.
START_TIME = Process.clock_gettime(Process::CLOCK_MONOTONIC)

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "draughts"

REQUIRED_WINS = 8
STRENGTH_GAMES = 10
PLY_CAP = 400
# The literal 8 of TASK-BRIEF section 2 and RUBRIC item 10, not Draughts::AI::HARD_FLOOR.
# A bar that reads the constant it is meant to police cannot catch the constant moving: the
# session-2 audit lowered HARD_FLOOR to 4 in a scratch copy and this check stayed green.
REQUIRED_DEPTH = 8
TIME_LIMIT = 3.0
HARD_PLY_CAP = 140
FAILURES = []

def clock
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def fail_with(message)
  FAILURES << message
  puts "  FAIL: #{message}"
end

def yjit_state
  return "not built into this Ruby" unless defined?(RubyVM::YJIT)

  RubyVM::YJIT.enabled? ? "on" : "off"
end

# One game between two levels. Draughts::Game is what plays the moves, so both draw rules
# are live: a repetition or eighty quiet plies ends the game as a draw and counts against
# the stronger side, which is what makes 8 of 10 a real bar rather than a formality.
def play_match(red_level, white_level, seed, ply_cap: PLY_CAP)
  random = Random.new(seed)
  game = Draughts::Game.new
  until game.finished? || game.plies >= ply_cap
    level = game.side_to_move == Draughts::Side::RED ? red_level : white_level
    game.play(Draughts::AI.choose(game.position, level: level, random: random).move)
  end
  game
end

# :win, :loss or :draw from the point of view of the side named by red_seat.
def outcome_for(game, red_seat)
  result = game.result || :ply_cap
  return :win if result == (red_seat ? :red_won : :white_won)
  return :loss if result == (red_seat ? :white_won : :red_won)

  :draw
end

# ---------------------------------------------------------------- fixtures
#
# Three positions, each with its provenance, because a timing number is worth only what the
# position it was measured on is worth.
LINE_MOVES = %w[11-15 22-18 15x22].freeze

def rubric_line_position
  game = Draughts::Game.new
  LINE_MOVES.each { |text| game.play(text) }
  game.position
end

# Twenty plies of Medium against Medium, both sides at Draughts::AI::MEDIUM_DEPTH with one
# Random seeded MIDGAME_SEED shared between them:
#
#   game = Draughts::Game.new
#   random = Random.new(20_260_902)
#   20.times { game.play(Draughts::AI.choose(game.position, level: :medium,
#                                            random: random).move) }
#
# which plays 11-15 22-18 15x22 25x18 10-15 18x11 7x16 23-19 16x23 26x19 2-7 24-20 7-11
# 27-24 11-15 19x10 6x15 24-19 15x24 28x19 and leaves seven men a side, Red to move, six
# legal moves, nothing crowned. MIDGAME_KEY is asserted against the replay below, so a
# change in the search or the evaluation that moves this fixture is reported instead of
# being quietly measured on a different board.
MIDGAME_SEED = 20_260_902
MIDGAME_PLIES = 20
MIDGAME_KEY = "r-rrr--rr--r------www-------wwww r"

# The worst position the session-2 audit found (its finding H1): ten pieces, all ten of them
# kings, fifteen legal moves and no capture available, so the branching factor is as wide as
# English draughts gets. It was reached by uniformly random legal play from the standard
# start (tests/audit/s2_reachable.rb), so it is not a synthetic board. Before the fix pass it
# took 3.2 to 6.0 seconds; it is a fixture here so that a regression in the cost of the depth
# floor fails this check instead of being found by the next audit.
AUDIT_WORST_KEY = "-W-W----WWW-------RR----RR-R---- w"

def midgame_position
  game = Draughts::Game.new
  random = Random.new(MIDGAME_SEED)
  MIDGAME_PLIES.times do
    break if game.finished?

    game.play(Draughts::AI.choose(game.position, level: :medium, random: random).move)
  end
  game.position
end

# ---------------------------------------------------------------- 0. header
puts "Draughts AI check (slow), Rails-free"
puts "  ruby            #{RUBY_VERSION} (#{RUBY_PLATFORM})"
puts "  yjit            #{yjit_state}"
puts "  Rails           #{Object.const_defined?(:Rails) ? "DEFINED (fail)" : "not defined (ok)"}"
fail_with("Rails is loaded") if Object.const_defined?(:Rails)
puts "  evaluation      #{Draughts::AI::Evaluation.weights}"
puts format("  hard            floor %d, cap %d, budget %.1f s, abort after %.1f s",
            Draughts::AI::HARD_FLOOR, Draughts::AI::HARD_CAP,
            Draughts::AI::HARD_BUDGET, Draughts::AI::HARD_ABORT_AFTER)
puts "  medium          fixed depth #{Draughts::AI::MEDIUM_DEPTH}"

# ---------------------------------------------------------------- 1. strength
puts
puts "1. Strength: Medium against Easy, #{STRENGTH_GAMES} games, draw rules live"
LABELS = { win: "Medium wins", loss: "EASY WINS", draw: "draw" }.freeze
tally = Hash.new(0)
reasons = Hash.new(0)
strength_started = clock
STRENGTH_GAMES.times do |index|
  medium_red = index.even?
  seed = 4000 + index
  game = play_match(medium_red ? :medium : :easy, medium_red ? :easy : :medium, seed)
  outcome = outcome_for(game, medium_red)
  tally[outcome] += 1
  reasons[game.reason || :ply_cap] += 1
  puts format("  game %2d  seed %d  Medium as %-5s  %3d plies  %-11s  %s",
              index + 1, seed, medium_red ? "Red" : "White", game.plies,
              LABELS.fetch(outcome), game.reason || :ply_cap)
end
puts format("  tally: Medium %d wins, %d losses, %d draws in %.1f s (needs %d wins): %s",
            tally[:win], tally[:loss], tally[:draw], clock - strength_started,
            REQUIRED_WINS, tally[:win] >= REQUIRED_WINS ? "PASS" : "FAIL")
puts "  reasons: #{reasons.sort_by { |_, count| -count }.to_h}"
if tally[:win] < REQUIRED_WINS
  fail_with("Medium won #{tally[:win]} of #{STRENGTH_GAMES}, needs #{REQUIRED_WINS}")
end

# ---------------------------------------------------------------- 2. timing
puts
puts "2. Hard timing: the depth reached and the seconds it took, measured twice"
FIXTURES = [
  [ "starting position", Draughts::Position.start ],
  [ "after #{LINE_MOVES.join(" ")}", rubric_line_position ],
  [ "midgame, #{MIDGAME_PLIES} plies of seeded Medium vs Medium", midgame_position ],
  [ "ten kings, the session-2 audit's worst reachable position",
    Draughts::Position.parse(AUDIT_WORST_KEY) ]
].freeze

if FIXTURES[2][1].key != MIDGAME_KEY
  fail_with("the midgame fixture is #{FIXTURES[2][1].key}, expected #{MIDGAME_KEY}")
end
FIXTURES.each { |name, position| puts "    #{name.ljust(56)} #{position.key}" }

# A short search before each block so the block measures a warm interpreter, and so the
# YJIT-on block is not paying for compiling what it is about to time.
def warm_up
  Draughts::AI::Search.fixed(Draughts::Position.start, depth: 6, random: Random.new(1))
end

def timing_block(label)
  puts "  #{label}"
  warm_up
  FIXTURES.each_with_index do |(name, position), index|
    started = clock
    choice = Draughts::AI.choose(position, level: :hard, random: Random.new(7000 + index))
    wall = clock - started
    puts format("    %-56s depth %2d  %7d nodes  %5.3f s wall (%5.3f searched)  %8.0f nodes/s  plays %-9s%s%s",
                name, choice.depth, choice.nodes, wall, choice.elapsed, choice.nodes / wall,
                choice.move.pdn, choice.forced? ? "  (forced)" : "",
                choice.complete? ? "" : "  (deadline hit)")
    if choice.depth < REQUIRED_DEPTH
      fail_with("#{label}: #{name} reached depth #{choice.depth}, needs #{REQUIRED_DEPTH}")
    end
    next unless wall > TIME_LIMIT

    fail_with(format("%s: %s took %.3f s, over the %.1f s limit", label, name, wall,
                     TIME_LIMIT))
  end
end

# The depth floor on its own, which is the work no deadline can shorten and the thing
# finding H1 was about. Printed for every fixture so a regression is visible as a number and
# not only as a pass or a fail.
def floor_block(label)
  puts "  #{label}: the depth-#{REQUIRED_DEPTH} floor on its own"
  FIXTURES.each do |name, position|
    started = clock
    floored = Draughts::AI::Search.iterative(position, floor: REQUIRED_DEPTH,
                                             cap: REQUIRED_DEPTH, budget: 1e9,
                                             abort_after: nil, random: Random.new(11))
    wall = clock - started
    puts format("    %-56s depth %2d  %7d nodes  %5.3f s wall  %8.0f nodes/s",
                name, floored.depth, floored.nodes, wall, floored.nodes / wall)
    next unless wall > TIME_LIMIT

    fail_with(format("%s: the floor alone on %s took %.3f s, over the %.1f s limit",
                     label, name, wall, TIME_LIMIT))
  end
end

timing_block("YJIT #{yjit_state} (as this process was launched)")
floor_block("YJIT #{yjit_state}")
if defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:enable)
  if RubyVM::YJIT.enabled?
    puts "  YJIT was already on (RUBY_YJIT_ENABLE is set), so both blocks are the same setting"
  else
    RubyVM::YJIT.enable
  end
  timing_block("YJIT #{yjit_state} (enabled from inside the process)")
  floor_block("YJIT #{yjit_state}")
else
  puts "  this Ruby has no RubyVM::YJIT.enable, so only one setting was measured"
end

# ---------------------------------------------------------------- 3. table
#
# The wide version of the fast suite's transposition-table test. A table that handed a bound
# back from inside the window would show up here as a changed score or a changed move.
puts
puts "3. Transposition table against no table, same depth"
table_positions = []
table_random = Random.new(9)
walk = Draughts::Game.new
until walk.finished? || walk.plies >= 24
  legal = walk.legal_moves
  break if legal.empty?

  table_positions << walk.position if walk.plies.even?
  walk.play(legal[table_random.rand(legal.length)])
end
table_started = clock
disagreements = 0
saved = 0
table_positions.each do |position|
  plain = Draughts::AI::Search.fixed(position, depth: 6, random: Random.new(3), table: false)
  tabled = Draughts::AI::Search.fixed(position, depth: 6, random: Random.new(3), table: true)
  saved += plain.nodes - tabled.nodes
  next if plain.score == tabled.score && plain.move == tabled.move

  disagreements += 1
  fail_with("the table changed the answer for #{position.key}")
end
puts format("  %d positions at depth 6: %d disagreements, %d nodes saved, %.1f s",
            table_positions.length, disagreements, saved, clock - table_started)

# ---------------------------------------------------------------- 4. Hard against Medium
puts
hard_games = ENV["DRAUGHTS_AI_HARD"].to_i
if hard_games.positive?
  puts "4. Hard against Medium, #{hard_games} games (informational, not graded)"
  hard_labels = { win: "Hard wins", loss: "MEDIUM WINS", draw: "draw" }
  hard_tally = Hash.new(0)
  hard_started = clock
  hard_games.times do |index|
    hard_red = index.even?
    seed = 5000 + index
    game = play_match(hard_red ? :hard : :medium, hard_red ? :medium : :hard, seed,
                      ply_cap: HARD_PLY_CAP)
    outcome = outcome_for(game, hard_red)
    hard_tally[outcome] += 1
    puts format("  game %2d  seed %d  Hard as %-5s  %3d plies  %-11s  %s",
                index + 1, seed, hard_red ? "Red" : "White", game.plies,
                hard_labels.fetch(outcome), game.reason || :ply_cap)
  end
  puts format("  tally: Hard %d wins, %d losses, %d draws in %.0f s",
              hard_tally[:win], hard_tally[:loss], hard_tally[:draw], clock - hard_started)
else
  puts "4. Hard against Medium: skipped, set DRAUGHTS_AI_HARD to a game count to run it"
end

# ---------------------------------------------------------------- verdict
puts
puts format("wall time %.1f s", clock - START_TIME)
if FAILURES.empty?
  puts "OK: Medium beat Easy #{tally[:win]} of #{STRENGTH_GAMES}, every Hard move reached " \
       "depth #{REQUIRED_DEPTH} or more inside #{TIME_LIMIT} s, the table changed nothing."
  exit 0
end
FAILURES.each { |reason| puts "FAIL: #{reason}" }
exit 1
