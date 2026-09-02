# frozen_string_literal: true

require "minitest/autorun"
require "draughts"
require_relative "clock_support"

# Negamax with alpha-beta: the scores it gives terminal positions, the moves it picks, the
# transposition table, and the three things that stop iterative deepening (the depth floor,
# the budget and the hard deadline), all driven by an injected clock so nothing waits.
class DraughtsAISearchTest < Minitest::Test
  include Draughts

  Search = Draughts::AI::Search

  # Red men on 23, 24 and 28 against a White man on 32, Red to move.
  #   24-27 leaves White with nothing: both its steps are blocked and its only jump lands on
  #         23, which is occupied. That is a win for Red on the next ply.
  #   23-26 also wins, but only after White plays 32-27 and Red answers, so it is slower.
  #   23-27 empties 23 and hands White the jump 32x23.
  # It is fixture F5 of CONCEPT.md 4.3 with one Red man moved back a square.
  def mate_in_one
    Position.build({ 23 => "r", 24 => "r", 28 => "r", 32 => "w" }, Side::RED)
  end

  # The same position after 24-27: White is to move and has no legal move at all.
  def stalemate
    Position.build({ 23 => "r", 27 => "r", 28 => "r", 32 => "w" }, Side::WHITE)
  end

  def test_the_side_to_move_with_no_legal_move_scores_as_a_loss
    assert_empty Rules.legal_moves(stalemate)
    assert_equal Search::LOSS_SCORE - 1, Search.score(stalemate, depth: 1)
    assert_equal Search::LOSS_SCORE - 4, Search.score(stalemate, depth: 4)
    assert_equal Search::LOSS_SCORE, Search.score(stalemate, depth: 0)
  end

  def test_a_loss_that_is_closer_is_worse_than_a_loss_that_is_further_off
    # The remaining depth is what makes the difference, so the same lost position is worth
    # less the more search was left when it was found. Negated by the parent, that is the
    # search preferring the quicker win.
    assert_operator Search.score(stalemate, depth: 5), :<, Search.score(stalemate, depth: 1)
  end

  def test_there_is_no_move_to_return_from_a_lost_position
    assert_nil Search.fixed(stalemate, depth: 4, random: Random.new(1))
    assert_nil Search.iterative(stalemate, floor: 2, cap: 2, random: Random.new(1))
  end

  def test_a_forced_win_is_found_and_preferred_over_a_slower_one
    position = mate_in_one

    assert_equal %w[23-26 23-27 24-27], Rules.legal_moves(position).map(&:pdn)
    scored = Rules.legal_moves(position).to_h do |move|
      [ move.pdn, -Search.score(Rules.apply(position, move), depth: 5) ]
    end

    assert_operator scored["24-27"], :>, Search::DECISIVE
    assert_operator scored["23-26"], :>, Search::DECISIVE
    assert_operator scored["24-27"], :>, scored["23-26"]
    assert_operator scored["23-27"], :<, Search::DECISIVE

    [ 2, 4, 6 ].each do |depth|
      result = Search.fixed(position, depth: depth, random: Random.new(depth))

      assert_equal "24-27", result.move.pdn, "depth #{depth} missed the mate in one"
      assert_equal 1, result.ties
      assert_operator result.score, :>, Search::DECISIVE
    end
  end

  def test_the_search_takes_the_capture_that_wins_the_most
    # Red on 14 may jump the White man on 17, or jump the one on 18 and go on over 27 to
    # crown on 32. Both are legal, only one wins two men.
    position = Position.build({ 14 => "r", 17 => "w", 18 => "w", 27 => "w" }, Side::RED)

    assert_equal %w[14x21 14x23x32], Rules.legal_moves(position).map(&:pdn)
    result = Search.fixed(position, depth: 4, random: Random.new(1))

    assert_equal "14x23x32", result.move.pdn
    assert_equal 1, result.ties
  end

  def test_the_search_refuses_the_move_that_hangs_a_man
    # 15-18 and 15-19 both walk into the White man on 23; 1-5 and 1-6 are safe and tie.
    position = Position.build({ 1 => "r", 15 => "r", 23 => "w", 32 => "w" }, Side::RED)
    scored = Rules.legal_moves(position).to_h do |move|
      [ move.pdn, -Search.score(Rules.apply(position, move), depth: 3) ]
    end

    assert_equal %w[1-5 1-6 15-18 15-19], scored.keys
    assert_operator scored["15-18"], :<, scored["1-5"] - Draughts::AI::Evaluation::MAN_VALUE
    assert_operator scored["15-19"], :<, scored["1-6"] - Draughts::AI::Evaluation::MAN_VALUE

    result = Search.fixed(position, depth: 4, random: Random.new(1))

    assert_includes %w[1-5 1-6], result.move.pdn
    assert_equal 2, result.ties
  end

  def test_the_result_reports_the_depth_the_nodes_and_the_elapsed_time
    clock = FakeClock.new(start: 10.0, step: 0.25)
    result = Search.fixed(Position.start, depth: 3, random: Random.new(1), clock: clock)

    assert_equal 3, result.depth
    assert_operator result.nodes, :>, 100
    assert_in_delta 0.25, result.elapsed, 1e-9
    assert_equal 2, clock.calls, "a fixed search with no deadline reads the clock twice"
    assert_predicate result, :complete?
  end

  # The table has to earn its complexity: fewer nodes, same answer. Correctness under a
  # wrong bound flag is pinned separately and exactly by
  # test_the_table_hands_a_bound_back_only_from_outside_the_window, and the wide statistical
  # version, twelve positions at depth 6, is in test/draughts_ai_check.rb.
  def test_the_transposition_table_cuts_the_node_count_and_changes_nothing_else
    positions = {
      # The widest of the four, so it is searched a ply shallower to stay inside the fast
      # suite's budget; the other three are cheap at six.
      [ "two kings and two men", 5 ] =>
        Position.build({ 6 => "R", 14 => "r", 19 => "w", 27 => "W" }, Side::RED),
      [ "kings only", 6 ] => Position.build({ 4 => "R", 8 => "R", 29 => "W" }, Side::RED)
    }

    positions.each do |(label, depth), position|
      plain = Search.fixed(position, depth: depth, random: Random.new(3), table: false)
      tabled = Search.fixed(position, depth: depth, random: Random.new(3), table: true)

      assert_equal plain.score, tabled.score, "the table changed the score of #{label}"
      assert_equal plain.move, tabled.move, "the table changed the move of #{label}"
      assert_operator tabled.nodes, :<, plain.nodes, "the table saved nothing on #{label}"
    end
  end
  # A plain negamax: no pruning, no table, no ordering, the same leaf rule the fixed-depth
  # search uses. Small positions only, because it is exponential.
  def plain(position, depth)
    moves = Rules.legal_moves(position)
    return Search::LOSS_SCORE - depth if moves.empty?
    return Draughts::AI::Evaluation.evaluate(position) if depth <= 0

    best = -Search::INFINITY
    moves.each { |move| best = [ best, -plain(Rules.apply(position, move), depth - 1) ].max }
    best
  end

  # Small positions with several pieces a side, so the tree has real transpositions and a
  # real cut-off pattern, but stays cheap enough for the fast suite.
  def oracle_positions
    {
      "kings and men" =>
        Position.build({ 6 => "R", 14 => "r", 19 => "w", 27 => "W" }, Side::RED),
      "three against three" =>
        Position.build({ 11 => "r", 15 => "r", 22 => "R", 18 => "w", 26 => "w",
                         30 => "W" }, Side::RED),
      "men racing to crown" =>
        Position.build({ 12 => "r", 20 => "r", 21 => "w", 29 => "w" }, Side::RED),
      "kings only" => Position.build({ 4 => "R", 8 => "R", 29 => "W" }, Side::RED),
      "white to move" =>
        Position.build({ 7 => "r", 16 => "R", 23 => "w", 24 => "w", 31 => "W" },
                       Side::WHITE),
      "a capture is forced" =>
        Position.build({ 14 => "r", 17 => "w", 18 => "w", 27 => "w" }, Side::RED)
    }
  end

  # The differential the session-2 audit ran wide: the alpha-beta score and the set of moves
  # attaining it must be exactly what an unpruned negamax says, with the table on and off.
  # The audit checked 3490 (position, depth) pairs; this is the cheap resident version, and
  # it is the thing that fails if the root window, the fail-soft contract or the table's
  # bound dispatch is wrong.
  def test_the_alpha_beta_score_and_tie_set_are_the_plain_negamax_ones
    oracle_positions.each do |label, position|
      # Depth 4 only where the tree is small enough to stay inside the fast suite's budget.
      depths = position.count <= 4 ? [ 3, 4 ] : [ 3 ]
      depths.each do |depth|
        moves = Rules.legal_moves(position)
        scored = moves.map { |move| -plain(Rules.apply(position, move), depth - 1) }
        want = scored.max
        best = moves.select.with_index { |_, at| scored[at] == want }

        [ false, true ].each do |table|
          result = Search.fixed(position, depth: depth, random: Random.new(3), table: table)

          assert_equal want, result.score, "#{label} d#{depth} table #{table}: score"
          assert_equal best.length, result.ties, "#{label} d#{depth} table #{table}: ties"
          assert_includes best, result.move, "#{label} d#{depth} table #{table}: move"
        end
      end
    end
  end

  # The bound dispatch, pinned directly rather than statistically. Replace the case in
  # Search.negamax with an unconditional "return value" (the session-2 audit's M1 mutant)
  # and the two refusal cases below go red at once.
  def test_the_table_hands_a_bound_back_only_from_outside_the_window
    position = oracle_positions["three against three"]
    truth = Search.score(position, depth: 3)

    # An upper bound says "worth at most this". Inside a full window it proves nothing, so
    # it must be ignored and the subtree searched.
    ignored_upper = Search::Run.new(table: true)
    ignored_upper.store(position, 9, -9999, Search::UPPER, nil)

    assert_equal truth, Search.negamax(ignored_upper, position, 3, -Search::INFINITY,
                                       Search::INFINITY)

    # A lower bound says "worth at least this". Same: it does not settle a full window.
    ignored_lower = Search::Run.new(table: true)
    ignored_lower.store(position, 9, 9999, Search::LOWER, nil)

    assert_equal truth, Search.negamax(ignored_lower, position, 3, -Search::INFINITY,
                                       Search::INFINITY)

    # The three cases where an entry may be used, so the test is not passing by never
    # reading the table at all.
    exact = Search::Run.new(table: true)
    exact.store(position, 9, 4242, Search::EXACT, nil)

    assert_equal 4242, Search.negamax(exact, position, 3, -Search::INFINITY,
                                      Search::INFINITY)

    usable_upper = Search::Run.new(table: true)
    usable_upper.store(position, 9, -9999, Search::UPPER, nil)

    assert_equal(-9999, Search.negamax(usable_upper, position, 3, -5000, Search::INFINITY))

    usable_lower = Search::Run.new(table: true)
    usable_lower.store(position, 9, 9999, Search::LOWER, nil)

    assert_equal 9999, Search.negamax(usable_lower, position, 3, -Search::INFINITY, 5000)
  end

  # A shallower entry must never be trusted for a deeper question.
  def test_a_shallow_table_entry_is_not_used_for_a_deeper_search
    position = oracle_positions["kings only"]
    truth = Search.score(position, depth: 4)
    run = Search::Run.new(table: true)
    run.store(position, 2, 4242, Search::EXACT, nil)

    assert_equal truth, Search.negamax(run, position, 4, -Search::INFINITY, Search::INFINITY)
  end

  def test_order_puts_the_biggest_capture_first_and_leaves_equal_ones_alone
    # 14x23x32 takes two men, 14x21 takes one.
    position = Position.build({ 14 => "r", 17 => "w", 18 => "w", 27 => "w" }, Side::RED)
    ordered = Search.order!(Rules.legal_moves(position))

    assert_equal %w[14x23x32 14x21], ordered.map(&:pdn)

    quiet = Rules.legal_moves(Position.start)

    assert_equal quiet.map(&:pdn), Search.order!(quiet.dup).map(&:pdn)
  end

  # A random source that says how many numbers were drawn from it.
  class CountingRandom
    attr_reader :draws

    def initialize(seed)
      @random = Random.new(seed)
      @draws = 0
    end

    def rand(limit)
      @draws += 1
      @random.rand(limit)
    end
  end

  def test_pick_draws_one_number_and_spreads_uniformly
    moves = Rules.legal_moves(Position.start)

    assert_equal 7, moves.length

    counted = CountingRandom.new(1)
    Search.pick(moves, counted)

    assert_equal 1, counted.draws

    random = Random.new(20)
    counts = Hash.new(0)
    7_000.times { counts[Search.pick(moves, random).pdn] += 1 }

    assert_equal 7, counts.length
    counts.each_value do |count|
      assert_includes 880..1120, count, "uneven draw: #{counts.inspect}"
    end
  end

  # The horizon. leaf_value is what the search uses at depth 0 when exact_leaves is off,
  # which is what Hard runs: it keeps the cheap half of the terminal test (a side with no
  # pieces has lost) and gives up the expensive half (a side whose every piece is blocked).
  def test_the_horizon_still_scores_a_side_with_nothing_left_as_a_loss
    wiped = Position.parse("----------------wwwwwwwwwwwwwwww r")

    assert_equal 0, wiped.count(Side::RED)
    assert_equal Search::LOSS_SCORE, Search.leaf_value(wiped)
    assert_equal Search::LOSS_SCORE, Search.score(wiped, depth: 0, exact_leaves: false)
    # LOSS_SCORE - depth at depth 0 is LOSS_SCORE, so both leaf rules agree here.
    assert_equal Search::LOSS_SCORE, Search.score(wiped, depth: 0, exact_leaves: true)
    assert_equal Draughts::AI::Evaluation.evaluate(Position.start),
                 Search.leaf_value(Position.start)
  end

  def test_the_horizon_gives_up_a_blockade_and_the_next_iteration_takes_it_back
    # A Red man on 11 against White kings on 8, 27 and 28: at depth 4 the blockade sits
    # exactly on the horizon, so the cheap leaf scores it as material. At depth 5 it is an
    # interior node again and both leaf rules see the loss. This is the whole cost of the
    # horizon, written down.
    position = Position.parse("-------W--r---------------WW---- r")

    assert_equal %w[11-15 11-16], Rules.legal_moves(position).map(&:pdn)
    [ 2, 3, 5 ].each do |depth|
      assert_equal Search.score(position, depth: depth, exact_leaves: true),
                   Search.score(position, depth: depth, exact_leaves: false),
                   "depth #{depth} should be the same under both leaf rules"
    end

    assert_equal Search::LOSS_SCORE, Search.score(position, depth: 4, exact_leaves: true)
    refute_equal Search::LOSS_SCORE, Search.score(position, depth: 4, exact_leaves: false)
    assert_equal Search::LOSS_SCORE - 1, Search.score(position, depth: 5, exact_leaves: false)
  end

  def test_the_fixed_depth_search_keeps_the_exact_horizon_and_iterative_deepening_does_not
    # Medium is the level the brief pins as a plain fixed-depth alpha-beta, so it keeps the
    # exact leaf; Hard is the level with a clock to answer to, so it takes the cheap one.
    assert Search::Run.new.exact_leaves
    assert Search::Run.new(exact_leaves: true).exact_leaves
    refute Search::Run.new(exact_leaves: false).exact_leaves

    position = Position.parse("-------W--r---------------WW---- r")

    assert_equal Search::LOSS_SCORE,
                 Search.fixed(position, depth: 4, random: Random.new(1)).score
    refute_equal Search::LOSS_SCORE,
                 Search.iterative(position, floor: 4, cap: 4, budget: 1e9,
                                  abort_after: nil, random: Random.new(1)).score
  end

  # The optional stop that outranks the depth floor. Off by default, because TASK-BRIEF 1.4
  # pins the floor; a caller that would rather bound the clock asks for it by name.
  def test_the_optional_hard_deadline_stops_below_the_floor_and_reports_the_truth
    clock = FakeClock.new(step: 1.0)
    result = Search.iterative(Position.start, floor: 8, cap: 14, budget: 1e9,
                              abort_after: nil, hard_deadline: 6.0, random: Random.new(1),
                              clock: clock)

    assert_operator result.depth, :<, 8, "the hard deadline has to be able to break the floor"
    assert_operator result.depth, :>=, 1, "depth 1 is never abandoned, a move always comes back"
    refute_predicate result, :complete?
    assert_includes Rules.legal_moves(Position.start), result.move
  end

  def test_without_the_hard_deadline_the_floor_still_beats_any_clock
    result = Search.iterative(Position.start, floor: 4, cap: 14, budget: 1e9,
                              abort_after: 0.0, hard_deadline: nil, random: Random.new(1),
                              clock: FakeClock.new(step: 1000.0))

    assert_equal 4, result.depth
    assert_predicate result, :complete?
    assert_nil Draughts::AI::HARD_DEADLINE, "the option ships off"
  end

  def test_the_hard_deadline_takes_the_earlier_of_the_two_stops
    started = 0.0

    assert_nil Search.iteration_deadline(started, 1, 8, 2.0, 0.5), "depth 1 is never stopped"
    assert_nil Search.iteration_deadline(started, 5, 8, 2.0, nil), "at the floor, abort_after sleeps"
    assert_in_delta 0.5, Search.iteration_deadline(started, 5, 8, 2.0, 0.5)
    assert_in_delta 2.0, Search.iteration_deadline(started, 9, 8, 2.0, nil)
    assert_in_delta 0.5, Search.iteration_deadline(started, 9, 8, 2.0, 0.5)
    assert_in_delta 2.0, Search.iteration_deadline(started, 9, 8, 2.0, 5.0)
  end

  # A forced move: nothing to choose, so iterative deepening honours the floor and stops
  # there instead of spending the whole budget on a search that cannot change the answer.
  def test_one_legal_move_stops_at_the_floor_and_is_reported_as_forced
    game = Game.new
    %w[11-15 22-18].each { |text| game.play(text) }

    assert_equal %w[15x22], game.legal_moves.map(&:pdn)
    result = Search.iterative(game.position, floor: 3, cap: 12, budget: 1e9,
                              abort_after: nil, random: Random.new(1))

    assert_equal 3, result.depth, "the floor is still honoured"
    assert_predicate result, :forced?
    assert_equal 1, result.ties
    assert_equal "15x22", result.move.pdn

    open = Search.iterative(Position.start, floor: 3, cap: 4, budget: 1e9, abort_after: nil,
                            random: Random.new(1))

    assert_equal 4, open.depth, "a real choice runs on to the cap"
    refute_predicate open, :forced?
    refute_predicate Search.fixed(Position.start, depth: 2, random: Random.new(1)), :forced?
    assert_predicate Search.fixed(game.position, depth: 2, random: Random.new(1)), :forced?
  end

  def test_iterative_deepening_finishes_the_floor_however_late_the_clock_says_it_is
    # Every reading of this clock is a hundred seconds after the one before, so the budget
    # and the hard deadline are both long gone; the floor still has to be searched.
    result = Search.iterative(Position.start, floor: 4, cap: 6, budget: 0.5,
                              abort_after: 0.1, random: Random.new(1),
                              clock: FakeClock.new(step: 100.0))

    assert_equal 4, result.depth
    assert_predicate result, :complete?
  end

  def test_iterative_deepening_starts_no_new_depth_once_the_budget_has_passed
    # start 0, then a second a reading: the search reads twice per iteration, so depth 3
    # finishes at 6.0 seconds and 6.0 is the first reading at or past the 5.0 budget.
    clock = FakeClock.new(step: 1.0)
    result = Search.iterative(Position.start, floor: 1, cap: 8, budget: 5.0,
                              abort_after: nil, random: Random.new(1), clock: clock)

    assert_equal 3, result.depth
    assert_predicate result, :complete?
    assert_in_delta 7.0, result.elapsed, 1e-9
  end

  def test_iterative_deepening_stops_at_the_cap_when_there_is_all_the_time_in_the_world
    result = Search.iterative(Position.start, floor: 1, cap: 3, budget: 1e9,
                              abort_after: nil, random: Random.new(1), clock: FakeClock.new)

    assert_equal 3, result.depth
    assert_predicate result, :complete?
  end

  def test_the_hard_deadline_throws_the_unfinished_iteration_away
    # Depth 1 finishes at 2.0 on this clock having taken 1.0, so the estimate for depth 2 is
    # 1.0 * FIRST_GROWTH * GROWTH_SAFETY = 4.05 and 2.0 + 4.05 fits inside a 7.0 stop.
    # Depth 2 then runs into the deadline four readings later and is thrown away.
    clock = FakeClock.new(step: 1.0)
    result = Search.iterative(Position.start, floor: 1, cap: 8, budget: 1e9,
                              abort_after: 7.0, random: Random.new(1), clock: clock)

    assert_equal 1, result.depth, "the last finished depth is what comes back"
    refute_predicate result, :complete?
  end

  def test_no_new_depth_is_started_that_the_estimate_says_would_be_thrown_away
    # The same clock with the stop one tenth of a second earlier: 2.0 + 4.05 is over 6.0, so
    # depth 2 never starts, nothing is wasted, and the result is a finished iteration even
    # though the budget is nowhere near.
    clock = FakeClock.new(step: 1.0)
    result = Search.iterative(Position.start, floor: 1, cap: 8, budget: 1e9,
                              abort_after: 6.0, random: Random.new(1), clock: clock)

    assert_equal 1, result.depth
    assert_predicate result, :complete?
    assert_in_delta 1.35, Search::GROWTH_SAFETY
  end

  def test_the_hard_deadline_never_fires_before_the_floor_is_reached
    # abort_after 0 means the deadline has passed before the first node, and the clock never
    # moves, so any iteration that sets a deadline dies at once. Depths 1 to 3 are the floor
    # and never set one.
    result = Search.iterative(Position.start, floor: 3, cap: 6, budget: 1e9,
                              abort_after: 0.0, random: Random.new(1), clock: FakeClock.new)

    assert_equal 3, result.depth
    refute_predicate result, :complete?
  end

  def test_the_clock_is_only_read_per_node_while_a_deadline_is_live
    without = FakeClock.new
    Search.iterative(Position.start, floor: 3, cap: 3, budget: 1e9, abort_after: nil,
                     random: Random.new(1), clock: without)

    assert_operator without.calls, :<, 12, "no deadline means no per-node reading"

    with = FakeClock.new
    result = Search.iterative(Position.start, floor: 2, cap: 3, budget: 1e9,
                              abort_after: 1e9, random: Random.new(1), clock: with)

    assert_equal 3, result.depth
    assert_operator with.calls, :>, 100, "a live deadline is read once a node"
  end

  def test_iterative_deepening_agrees_with_a_fixed_search_of_the_same_depth
    position = Position.build({ 1 => "r", 15 => "r", 23 => "w", 32 => "w" }, Side::RED)
    fixed = Search.fixed(position, depth: 6, random: Random.new(4))
    deepened = Search.iterative(position, floor: 6, cap: 6, budget: 1e9, abort_after: nil,
                                random: Random.new(4), table: false)

    assert_equal fixed.score, deepened.score
    assert_equal fixed.move, deepened.move
    assert_equal 6, deepened.depth
  end

  def test_a_cap_below_the_floor_is_refused
    assert_raises(ArgumentError) do
      Search.iterative(Position.start, floor: 8, cap: 4, random: Random.new(1))
    end
  end

  def test_promote_first_moves_one_move_to_the_front_and_keeps_the_rest_in_order
    moves = Rules.legal_moves(Position.start)
    wanted = moves[4]

    assert_equal "11-15", wanted.pdn
    assert_equal %w[11-15 9-13 9-14 10-14 10-15 11-16 12-16],
                 Search.promote_first(moves.dup, wanted).map(&:pdn)
    assert_equal moves.map(&:pdn), Search.promote_first(moves.dup, nil).map(&:pdn)
    other = Position.build({ 1 => "r" }, Side::RED)

    assert_equal moves.map(&:pdn),
                 Search.promote_first(moves.dup, Rules.legal_moves(other).first).map(&:pdn)
  end

  def test_every_move_that_ties_for_the_best_score_is_counted
    # Two plies from the start the seven openings are still worth exactly the same, so the
    # whole move list goes into the draw.
    result = Search.fixed(Position.start, depth: 2, random: Random.new(1))

    assert_equal 7, result.ties
    assert_equal 0, result.score
    assert_includes Rules.legal_moves(Position.start), result.move
  end
end
