# frozen_string_literal: true

require "minitest/autorun"
require "draughts"

# Port of provided/source-libgdx/model/test/ValueTypesTest.java (4 cases), the value types
# of the delivered desktop version. Each test keeps its Java name.
#
# What changed in the port and why: the Java Square is a (column, row) record and the Java
# Move is one leg with at most one captured square. Here a square is its PDN number 1 to 32
# and a Move is a whole jump sequence (see move_test.rb and rules_test.rb), so the Java
# geometry is written through Draughts::Square.at(column, row) to keep the mapping visible.
class JavaPortValueTypesTest < Minitest::Test
  include Draughts

  # Java: sidesReturnTheirOpponent
  def test_sides_return_their_opponent
    assert_equal Side::WHITE, Side.opponent(Side::RED)
    assert_equal Side::RED, Side.opponent(Side::WHITE)
    assert_raises(Draughts::InvalidPosition) { Side.opponent(:green) }
  end

  # Java: squareReportsBoardValidityAndPlayability
  def test_square_reports_board_validity_and_playability
    assert Square.valid?(0, 0)
    assert Square.valid?(7, 7)
    refute Square.valid?(-1, 0)
    refute Square.valid?(8, 7)

    assert Square.playable?(0, 0)
    assert Square.playable?(7, 7)
    refute Square.playable?(0, 1)
    refute Square.playable?(8, 8)
    assert_equal 8, Square::BOARD_SIZE
  end

  # Java: piecePromotionIsImmutableAndIdempotent
  def test_piece_promotion_is_immutable_and_idempotent
    man = Piece::RED_MAN
    king = man.promote

    refute man.king?
    assert king.king?
    assert_equal Side::RED, king.side
    assert_same king, king.promote
    assert man.frozen?
    assert_raises(Draughts::InvalidPosition) { Piece[nil, false] }
  end

  # Java: movesIdentifyCapturesAndRequireEndpoints
  def test_moves_identify_captures_and_require_endpoints
    from = Square.at(0, 2)
    to = Square.at(1, 3)
    step = Move.new(origin: from, landings: [ to ])
    jump = Move.new(origin: from, landings: [ Square.at(2, 4) ], captures: [ Square.at(1, 3) ])

    refute step.capture?
    assert_empty step.captures
    assert jump.capture?
    assert_equal [ Square.at(1, 3) ], jump.captures
    assert_raises(Draughts::InvalidPosition) { Move.new(origin: nil, landings: [ to ]) }
    assert_raises(Draughts::InvalidPosition) { Move.new(origin: from, landings: []) }
  end
end
