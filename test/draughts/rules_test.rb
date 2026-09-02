# frozen_string_literal: true

require "minitest/autorun"
require "draughts"

# Every rule in TASK-BRIEF.md section 1.1, exercised against the generator, plus the
# leg-by-leg interface the web request uses. The fixtures F1 to F7b of section 2 live in
# fixtures_test.rb; this file is about the rules themselves.
class DraughtsRulesTest < Minitest::Test
  include Draughts

  # -- men ---------------------------------------------------------------------------

  def test_a_man_steps_one_square_diagonally_forward
    red = Position.build({ 15 => "r", 29 => "W" }, Side::RED)
    assert_equal [ "15-18", "15-19" ], pdn(red), "Red men move toward row 7"

    white = Position.build({ 18 => "w", 4 => "R" }, Side::WHITE)
    assert_equal [ "18-14", "18-15" ], pdn(white), "White men move toward row 0"

    Rules.legal_moves(red).each do |move|
      assert_equal 1, move.leg_count
      assert_includes Square::KING_DIRECTIONS.map { |d| Square.step(15, d) }, move.destination,
                      "a man moves exactly one square"
    end
  end

  def test_a_man_has_no_backward_destination_even_with_an_empty_square_behind_it
    position = Position.build({ 15 => "r", 29 => "W" }, Side::RED)

    assert position.empty?(10), "square 10 is behind the Red man and empty"
    assert position.empty?(11)
    refute_includes pdn(position), "15-10"
    refute_includes pdn(position), "15-11"
  end

  def test_a_man_captures_forward_only_by_jumping_onto_the_empty_square_beyond
    position = Position.build({ 11 => "r", 15 => "w", 29 => "W" }, Side::RED)

    assert_equal [ "11x18" ], pdn(position)
    move = Rules.legal_moves(position).first
    assert_equal [ 15 ], move.captures
    assert_equal 18, move.destination
  end

  def test_a_man_never_captures_backward
    # F4c: a Red man on 15 with a White man behind it on 11 and square 8 empty.
    position = Position.build({ 15 => "r", 11 => "w", 29 => "W" }, Side::RED)

    assert position.empty?(8), "the landing square behind the man is empty"
    assert_equal [ "15-18", "15-19" ], pdn(position)
    refute Rules.capture_available?(position)
  end

  # -- kings -------------------------------------------------------------------------

  def test_a_king_moves_one_square_in_all_four_directions_and_never_further
    position = Position.build({ 15 => "R", 29 => "W" }, Side::RED)
    steps = Square::KING_DIRECTIONS.map { |direction| Square.step(15, direction) }

    assert_equal [ "15-10", "15-11", "15-18", "15-19" ], pdn(position)
    assert_equal steps.compact.sort, Rules.legal_moves(position).map(&:destination).sort,
                 "a king reaches its four neighbours and nothing beyond them"
    assert_empty Rules.legal_moves(position).select(&:capture?)
  end

  def test_a_king_captures_in_all_four_directions_including_backward
    # A White king in the middle with a Red man on each of its four diagonals.
    centre = Square.number(4, 4)
    around = Square::KING_DIRECTIONS.map { |direction| Square.step(centre, direction) }
    landings = Square::KING_DIRECTIONS.map { |direction| Square.jump(centre, direction).last }
    pieces = { centre => "W" }
    around.each { |square| pieces[square] = "r" }
    position = Position.build(pieces, Side::WHITE)

    assert_equal landings.sort, Rules.legal_moves(position).map(&:destination).sort
    assert Rules.legal_moves(position).all?(&:capture?)
    assert Rules.legal_moves(position).all? { |move| move.capture_count == 1 },
           "no continuation is possible from any of the four landings"

    backward = Rules.legal_moves(position).find { |move| Square.row(move.destination) > 4 }
    refute_nil backward, "a king captures backward, toward its own promotion row"
  end

  # -- mandatory capture -------------------------------------------------------------

  def test_one_available_jump_refuses_every_quiet_move_of_the_whole_side
    # F1: Red men on 11 and 4, White man on 15. 4-8 and 11-16 are refused.
    position = Position.build({ 11 => "r", 4 => "r", 15 => "w" }, Side::RED)

    assert Rules.capture_available?(position)
    assert_equal [ "11x18" ], pdn(position)
    assert_empty Rules.legal_moves_from(position, 4), "the man on 4 has a step but no jump"
    assert_empty Rules.legal_targets(position, 4)
    assert_equal [ 18 ], Rules.legal_targets(position, 11)
  end

  def test_every_piece_that_can_jump_stays_eligible
    position = Position.build({ 4 => "r", 1 => "r", 8 => "w", 6 => "w" }, Side::RED)

    assert_equal [ "1x10", "4x11" ], pdn(position)
    assert_equal [ 1, 4 ], Rules.legal_moves(position).map(&:origin)
  end

  # TASK-BRIEF.md 1.1: "When several captures are available the player chooses freely
  # (there is no maximum-capture rule)."
  def test_there_is_no_maximum_capture_rule
    position = leg_position
    moves = Rules.legal_moves(position)

    assert_equal [ "23x16", "24x15x8" ], moves.map(&:pdn)
    assert_equal [ 1, 2 ], moves.map(&:capture_count),
                 "the one-capture move is legal beside the two-capture move"
    assert_includes Rules.legal_targets(position, 23), 16
    assert_equal [ "23x16" ], Rules.moves_matching(position, [ 23, 16 ]).map(&:pdn)
  end

  def test_a_jump_needs_an_opponent_and_an_empty_landing_square
    own_piece_in_the_way = Position.build({ 11 => "r", 15 => "r", 29 => "W" }, Side::RED)
    refute Rules.capture_available?(own_piece_in_the_way)

    landing_occupied = Position.build({ 11 => "r", 15 => "w", 18 => "r", 29 => "W" }, Side::RED)
    refute Rules.capture_available?(landing_occupied)
    refute_includes pdn(landing_occupied), "11x18"
  end

  # -- jump sequences ----------------------------------------------------------------

  def test_a_jumping_piece_must_keep_jumping_and_the_sequence_is_one_move
    # F2: a Red man on 4 takes the White men on 8 and 15 in a single move.
    position = Position.build({ 4 => "r", 8 => "w", 15 => "w" }, Side::RED)
    moves = Rules.legal_moves(position)

    assert_equal 1, moves.length
    assert_equal "4x11x18", moves.first.pdn
    assert_equal [ 8, 15 ], moves.first.captures
    assert_equal [ 11, 18 ], moves.first.landings
    assert_equal 2, moves.first.leg_count
    refute_includes pdn(position), "4x11", "stopping half way through is not a move"
  end

  def test_the_player_chooses_freely_among_continuations
    position = Position.build({ 3 => "r", 7 => "w", 15 => "w", 14 => "w" }, Side::RED)

    assert_equal [ "3x10x17", "3x10x19" ], pdn(position)
    assert_equal [ 17, 19 ], Rules.continuations(position, [ 3, 10 ])
    assert_equal [ 10 ], Rules.legal_targets(position, 3), "both moves share their first leg"
  end

  def test_no_piece_may_be_jumped_twice_in_one_move
    # A Red king on 11 ringed by four White men. Each way round the ring takes all four and
    # comes home; without the rule the king would jump the same man back and forth forever.
    position = ring_position

    assert_equal [ "11x2x9x18x11", "11x18x9x2x11" ], pdn(position)
    Rules.legal_moves(position).each do |move|
      assert_equal 4, move.capture_count
      assert_equal [ 6, 7, 14, 15 ], move.captures.sort, "each White man is taken exactly once"
      assert_equal move.captures.uniq, move.captures
    end
  end

  def test_the_origin_square_counts_as_empty_during_a_sequence
    position = ring_position

    Rules.legal_moves(position).each do |move|
      assert_equal 11, move.destination, "the sequence ends where it started"
    end
    after = Rules.apply(position, Rules.legal_moves(position).first)
    assert_equal Piece::RED_KING, after.at(11)
    assert_equal 0, after.count(Side::WHITE)
  end

  def test_a_jumped_piece_is_not_removed_until_the_move_ends
    # The rule has one observable consequence in English draughts: a landing square is never
    # a square a jumped piece stands on (they lie on opposite square parities), so what it
    # forbids is jumping the same piece a second time, which the ring position proves.
    position = ring_position
    Rules.legal_moves(position).each do |move|
      move.landings.each do |landing|
        refute_includes move.captures, landing
        assert position.empty?(landing) || landing == move.origin
      end
    end
  end

  # -- promotion ---------------------------------------------------------------------

  def test_a_man_reaching_the_far_row_is_crowned
    position = Position.build({ 27 => "r", 1 => "W" }, Side::RED)
    move = Rules.move!(position, "27-32")

    assert move.promotion?
    after = Rules.apply(position, move)
    assert_equal Piece::RED_KING, after.at(32)
    assert_nil after.at(27)
    assert_equal Side::WHITE, after.side_to_move
  end

  def test_white_promotes_on_row_zero
    position = Position.build({ 8 => "w", 25 => "r" }, Side::WHITE)
    move = Rules.move!(position, "8-4")

    assert move.promotion?
    assert_equal Piece::WHITE_KING, Rules.apply(position, move).at(4)
  end

  def test_promotion_during_a_jump_ends_the_move_at_once
    # F3: the Red man on 24 takes 27 and lands crowned on 31; it does not go on to take 26.
    position = Position.build({ 24 => "r", 27 => "w", 26 => "w" }, Side::RED)

    assert_equal [ "24x31" ], pdn(position)
    refute_includes pdn(position), "24x31x22"
    move = Rules.legal_moves(position).first
    assert move.promotion?
    assert_equal [ 27 ], move.captures

    after = Rules.apply(position, move)
    assert_equal Piece::RED_KING, after.at(31)
    assert_equal Piece::WHITE_MAN, after.at(26), "the second White man survives"
    assert_equal Side::WHITE, after.side_to_move
    assert_empty Rules.continuations(position, [ 24, 31 ])
  end

  def test_a_king_that_was_already_a_king_is_not_flagged_as_a_promotion
    position = Position.build({ 27 => "R", 1 => "W" }, Side::RED)
    move = Rules.move!(position, "27-32")

    refute move.promotion?
    assert_equal Piece::RED_KING, Rules.apply(position, move).at(32)
  end

  # -- the opening and ordering ------------------------------------------------------

  def test_the_opening_position_has_exactly_the_seven_standard_moves_for_each_side
    assert_equal %w[9-13 9-14 10-14 10-15 11-15 11-16 12-16], pdn(Position.start)
    assert_equal %w[21-17 22-17 22-18 23-18 23-19 24-19 24-20],
                 pdn(Position.start.with_side(Side::WHITE))
  end

  def test_generation_is_deterministic_and_ordered_by_origin_then_path
    position = Position.build({ 3 => "r", 7 => "w", 15 => "w", 14 => "w" }, Side::RED)
    ordered = Rules.legal_moves(Position.start).map(&:squares)

    assert_equal ordered.sort, ordered
    assert_equal ordered, Rules.legal_moves(Position.start).map(&:squares)
    assert_equal pdn(position), pdn(position)
  end

  def test_generated_moves_are_fresh_arrays_of_frozen_values
    first = Rules.legal_moves(Position.start)
    first << Move.new(origin: 1, landings: [ 5 ])

    assert_equal 7, Rules.legal_moves(Position.start).length,
                 "changing a returned list cannot change the engine"
    assert Rules.legal_moves(Position.start).all?(&:frozen?)
  end

  # -- applying a move ---------------------------------------------------------------

  def test_apply_moves_the_piece_takes_the_captures_and_hands_over_the_turn
    position = Position.build({ 4 => "r", 8 => "w", 15 => "w", 29 => "W" }, Side::RED)
    after = Rules.apply(position, Rules.move!(position, "4x11x18"))

    assert_nil after.at(4)
    assert_nil after.at(8)
    assert_nil after.at(15)
    assert_equal Piece::RED_MAN, after.at(18)
    assert_equal Side::WHITE, after.side_to_move
    assert_equal 1, after.count(Side::WHITE)
  end

  def test_apply_keeps_a_king_a_king
    position = Position.build({ 15 => "R", 29 => "W" }, Side::RED)
    after = Rules.apply(position, Rules.move!(position, "15-10"))

    assert_equal Piece::RED_KING, after.at(10)
  end

  # The contract, pinned so that changing it is a decision and not an accident: Rules.apply
  # is the unchecked fast path that perft and the AI run millions of times, and every public
  # entry point a request can reach validates before it applies.
  def test_apply_is_the_unchecked_fast_path_and_the_named_entry_points_validate
    position = Position.build({ 11 => "r", 15 => "w" }, Side::RED)
    bogus = Move.new(origin: 11, landings: [ 30 ])

    assert_equal [ "11x18" ], pdn(position)
    assert_equal "--------------w--------------r-- w", Rules.apply(position, bogus).key,
                 "apply trusts its caller and does not re-derive legality"

    assert_raises(Draughts::IllegalMove) { Rules.move!(position, "11-30") }
    assert_nil Rules.find_move(position, "11-30")
    refute Rules.legal?(position, bogus)
    assert_raises(Draughts::IllegalMove) { Rules.apply_leg(position, [ 11 ], 30) }

    game = Game.new(position)
    assert_raises(Draughts::IllegalMove) { game.play(bogus) }
    assert_raises(Draughts::IllegalMove) { game.play("11-30") }
    assert_raises(Draughts::IllegalMove) { game.play_leg(11, 30) }
    assert_equal position, game.position, "nothing illegal changed the position"
  end

  def test_find_move_and_move_bang
    assert_equal "11-15", Rules.find_move(Position.start, "11-15").pdn
    assert_nil Rules.find_move(Position.start, "11-16x20")
    assert_nil Rules.find_move(Position.start, "1-5")
    assert_raises(Draughts::IllegalMove) { Rules.move!(Position.start, "1-5") }
    move = Rules.move!(Position.start, "11-15")
    assert_equal move, Rules.find_move(Position.start, move)
    assert Rules.legal?(Position.start, move)
    refute Rules.legal?(Position.start, Move.new(origin: 1, landings: [ 5 ]))
  end

  # -- leg by leg --------------------------------------------------------------------

  # One call gives a whole board its destination dots, which is what a page render needs.
  def test_targets_by_origin_covers_the_whole_board_in_one_pass
    from_start = Rules.targets_by_origin(Position.start)

    assert_equal [ 9, 10, 11, 12 ], from_start.keys
    assert_equal [ 13, 14 ], from_start[9]
    assert_equal [ 16 ], from_start[12]
    assert_equal from_start.keys.to_h { |square| [ square, Rules.legal_targets(Position.start, square) ] },
                 from_start

    forced = Rules.targets_by_origin(Position.build({ 11 => "r", 4 => "r", 15 => "w" }, Side::RED))
    assert_equal({ 11 => [ 18 ] }, forced, "a piece with no legal move is absent")

    both = Rules.targets_by_origin(leg_position)
    assert_equal({ 23 => [ 16 ], 24 => [ 15 ] }, both)
  end

  def test_a_pending_path_offers_only_its_own_continuations
    position = leg_position

    assert_equal [ "23x16", "24x15x8" ], pdn(position)
    assert_equal [ 15 ], Rules.continuations(position, [ 24 ])
    assert_equal [ 8 ], Rules.continuations(position, [ 24, 15 ])
    assert_equal [ "24x15x8" ], Rules.moves_matching(position, [ 24, 15 ]).map(&:pdn)
    assert_nil Rules.complete_move(position, [ 24, 15 ]), "the sequence must continue"
    assert_equal "24x15x8", Rules.complete_move(position, [ 24, 15, 8 ]).pdn
  end

  def test_apply_leg_reports_when_the_sequence_is_complete
    position = leg_position

    first = Rules.apply_leg(position, [ 24 ], 15)
    refute first.complete?
    assert first.pending?
    assert_equal [ 24, 15 ], first.path
    assert_nil first.move

    second = Rules.apply_leg(position, first.path, 8)
    assert second.complete?
    assert_equal "24x15x8", second.move.pdn
    assert_equal [ 24, 15, 8 ], second.path
  end

  def test_apply_leg_refuses_an_illegal_or_non_continuation_leg
    position = leg_position

    assert_raises(Draughts::IllegalMove) { Rules.apply_leg(position, [ 24 ], 20) }
    assert_raises(Draughts::IllegalMove) { Rules.apply_leg(position, [ 24, 15 ], 19) }
    assert_raises(Draughts::InvalidPosition) { Rules.apply_leg(position, [], 15) }
    assert_raises(Draughts::InvalidPosition) { Rules.apply_leg(position, [ 24 ], 33) }
  end

  def test_a_quiet_move_completes_in_one_leg
    result = Rules.apply_leg(Position.start, [ 11 ], 15)

    assert result.complete?
    assert_equal "11-15", result.move.pdn
  end

  def test_pending_captures_and_the_board_shown_part_way_through_a_sequence
    position = leg_position

    assert_equal [], Rules.pending_captures([ 24 ])
    assert_equal [ 19 ], Rules.pending_captures([ 24, 15 ])
    assert_equal [ 19, 11 ], Rules.pending_captures([ 24, 15, 8 ])

    part_way = Rules.pending_position(position, [ 24, 15 ])
    assert_equal Piece::WHITE_MAN, part_way.at(15), "the jumping piece is on its landing square"
    assert_nil part_way.at(24)
    assert_nil part_way.at(19), "the piece it has taken is shown gone"
    assert_equal Piece::RED_MAN, part_way.at(11), "the piece it has not reached yet is still there"
    assert_equal Side::WHITE, part_way.side_to_move, "the mover is still to move"
    assert_same position, Rules.pending_position(position, [ 24 ])
  end

  def test_the_pending_board_crowns_a_man_that_finished_on_the_far_row
    position = Position.build({ 24 => "r", 27 => "w", 26 => "w" }, Side::RED)

    assert_equal Piece::RED_KING, Rules.pending_position(position, [ 24, 31 ]).at(31)
  end

  private

  def pdn(position)
    Rules.legal_moves(position).map(&:pdn)
  end

  # A Red king on 11 with White men on 7, 6, 14 and 15: the ring the king can jump all the
  # way round, in either direction, ending back on 11.
  def ring_position
    Position.build({ 11 => "R", 15 => "w", 14 => "w", 6 => "w", 7 => "w" }, Side::RED)
  end

  # White to move with two jumps available: the short one 23x16 and the two-leg 24x15x8.
  # The Red man on 7 is what stops 23x16 from continuing, so the two moves differ in length.
  def leg_position
    Position.build({ 24 => "w", 23 => "w", 19 => "r", 11 => "r", 7 => "r" }, Side::WHITE)
  end
end
