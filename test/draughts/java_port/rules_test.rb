# frozen_string_literal: true

require "minitest/autorun"
require "draughts"

# Port of provided/source-libgdx/model/test/RulesTest.java (10 cases). Each test keeps its
# Java name and its coordinates, written through Draughts::Square.at(column, row).
#
# What changed in the port and why: the Java Rules.captureMovesFrom returned the single
# jumps available to one square, because the Java model committed a multi-jump one leg at a
# time. Here legal_moves returns complete sequences, so a Java case that asserted one leg is
# ported as an assertion about the whole move and, where the Java case was about the leg
# offered next, as an assertion about Rules.continuations.
class JavaPortRulesTest < Minitest::Test
  include Draughts

  # Java: openingPositionHasSevenForwardMovesForEachSide
  def test_opening_position_has_seven_forward_moves_for_each_side
    red_moves = Rules.legal_moves(Position.start)
    white_moves = Rules.legal_moves(Position.start.with_side(Side::WHITE))

    assert_equal 7, red_moves.length
    assert_equal 7, white_moves.length
    assert red_moves.all? { |move| Square.row(move.destination) > Square.row(move.origin) }
    assert white_moves.all? { |move| Square.row(move.destination) < Square.row(move.origin) }
  end

  # Java: menOnlyStepAndCaptureForward
  def test_men_only_step_and_capture_forward
    board = Position.build({ Square.at(2, 2) => "r", Square.at(3, 3) => "w",
                             Square.at(1, 1) => "w" }, Side::RED)
    captures = Rules.legal_moves_from(board, Square.at(2, 2))

    assert_equal 1, captures.length
    assert_equal Square.at(4, 4), captures.first.destination
    assert_equal [ Square.at(3, 3) ], captures.first.captures
    refute_includes captures.map(&:destination), Square.at(0, 0)

    white = Position.build({ Square.at(4, 4) => "w" }, Side::WHITE)
    assert_equal [ Square.at(3, 3), Square.at(5, 3) ].sort,
                 Rules.legal_targets(white, Square.at(4, 4)).sort
  end

  # Java: whiteMenAlsoCaptureForwardOnly
  def test_white_men_also_capture_forward_only
    board = Position.build({ Square.at(4, 4) => "w", Square.at(3, 3) => "r",
                             Square.at(5, 5) => "r" }, Side::WHITE)
    captures = Rules.legal_moves_from(board, Square.at(4, 4))

    assert_equal 1, captures.length
    assert_equal Square.at(2, 2), captures.first.destination
    assert_equal [ Square.at(3, 3) ], captures.first.captures
    refute_includes captures.map(&:destination), Square.at(6, 6)
  end

  # Java: anyCaptureSuppressesEverySimpleMoveForTheSide
  def test_any_capture_suppresses_every_simple_move_for_the_side
    board = Position.build({ Square.at(0, 2) => "r", Square.at(2, 2) => "r",
                             Square.at(3, 3) => "w" }, Side::RED)
    all = Rules.legal_moves(board)

    assert_equal 1, all.length
    assert all.first.capture?
    assert_equal Square.at(2, 2), all.first.origin
    assert_empty Rules.legal_moves_from(board, Square.at(0, 2))
  end

  # Java: allPiecesWithCapturesRemainEligible
  def test_all_pieces_with_captures_remain_eligible
    board = Position.build({ Square.at(0, 0) => "r", Square.at(6, 0) => "r",
                             Square.at(1, 1) => "w", Square.at(5, 1) => "w" }, Side::RED)
    captures = Rules.legal_moves(board)

    assert_equal 2, captures.length
    assert_equal [ Square.at(0, 0), Square.at(6, 0) ].sort, captures.map(&:origin).sort
    assert captures.all?(&:capture?)
  end

  # Java: captureRequiresAnOpponentAndAnEmptyLandingSquare
  def test_capture_requires_an_opponent_and_an_empty_landing_square
    own_piece = Position.build({ Square.at(2, 2) => "r", Square.at(3, 3) => "r" }, Side::RED)
    refute Rules.capture_available?(own_piece)

    blocked = Position.build({ Square.at(2, 2) => "r", Square.at(3, 3) => "w",
                               Square.at(4, 4) => "r" }, Side::RED)
    refute Rules.capture_available?(blocked)
  end

  # Java: kingsStepInAllFourDirectionsWithoutFlying
  def test_kings_step_in_all_four_directions_without_flying
    board = Position.build({ Square.at(4, 4) => "R" }, Side::RED)
    moves = Rules.legal_moves_from(board, Square.at(4, 4))

    assert_equal [ Square.at(3, 3), Square.at(5, 3), Square.at(3, 5), Square.at(5, 5) ].sort,
                 moves.map(&:destination).sort
    assert_empty moves.select(&:capture?)
    refute_includes moves.map(&:destination), Square.at(6, 6)
    refute_includes moves.map(&:destination), Square.at(2, 2)
  end

  # Java: kingsCanCaptureInAllFourDirectionsButOnlyOverAdjacentPieces
  def test_kings_can_capture_in_all_four_directions_but_only_over_adjacent_pieces
    board = Position.build({ Square.at(4, 4) => "W", Square.at(3, 3) => "r",
                             Square.at(5, 3) => "r", Square.at(3, 5) => "r",
                             Square.at(5, 5) => "r" }, Side::WHITE)
    moves = Rules.legal_moves_from(board, Square.at(4, 4))

    assert_equal [ Square.at(2, 2), Square.at(6, 2), Square.at(2, 6), Square.at(6, 6) ].sort,
                 moves.map(&:destination).sort
    assert moves.all?(&:capture?)
    assert moves.all? { |move| move.capture_count == 1 }
  end

  # Java: edgesAndWrongSideSquaresHaveNoIllegalMoves
  def test_edges_and_wrong_side_squares_have_no_illegal_moves
    board = Position.build({ Square.at(0, 0) => "w", Square.at(6, 6) => "r" }, Side::WHITE)

    assert_empty Rules.legal_moves_from(board, Square.at(0, 0)),
                 "a White man on row 0 has nowhere forward to go"
    assert_empty Rules.legal_moves_from(board.with_side(Side::RED), Square.at(0, 0)),
                 "the square holds a White piece, so Red has no move from it"
    assert_empty Rules.legal_moves_from(board.with_side(Side::RED), Square.at(1, 1)),
                 "an empty square has no moves"
    assert_nil Square.at(-2, -2), "an off-board coordinate has no square number"
    assert_raises(Draughts::InvalidPosition) { Rules.legal_moves_from(board, 33) }
  end

  # Java: generatedMoveListsCannotBeMutated
  def test_generated_move_lists_cannot_be_mutated
    board = Position.build({ Square.at(2, 2) => "r", Square.at(0, 6) => "w" }, Side::RED)
    moves = Rules.legal_moves(board)
    moves << Move.new(origin: 1, landings: [ 5 ])
    moves.first.landings.freeze

    assert_equal 2, Rules.legal_moves(board).length,
                 "the engine hands out a fresh list, so changing one cannot change it"
    assert Rules.legal_moves(board).all?(&:frozen?)
    assert Rules.legal_moves(board).all? { |move| move.landings.frozen? && move.captures.frozen? }
    assert_raises(FrozenError) { Rules.legal_moves(board).first.landings << 1 }
  end
end
