# frozen_string_literal: true

require "minitest/autorun"
require "draughts"

# Port of provided/source-libgdx/model/test/BoardTest.java (4 cases). Each test keeps its
# Java name.
#
# What changed in the port and why: the Java Board is mutable, with reset, clear and
# setPiece. Draughts::Position is an immutable value, so reset becomes Position.start,
# clear plus setPiece becomes Position.build, and "mutate then reset" becomes "the copy
# changed and the original did not".
class JavaPortBoardTest < Minitest::Test
  include Draughts

  # Java: resetCreatesTheExactOpeningPosition
  def test_reset_creates_the_exact_opening_position
    board = Position.start

    assert_equal 12, board.count(Side::RED)
    assert_equal 12, board.count(Side::WHITE)

    (0...8).each do |row|
      (0...8).each do |col|
        piece = board.at_coordinates(col, row)
        if !Square.playable?(col, row) || row == 3 || row == 4
          assert_nil piece, "expected an empty square at #{col},#{row}"
          next
        end

        assert_equal(row <= 2 ? Side::RED : Side::WHITE, piece.side)
        refute piece.king?
      end
    end
  end

  # Java: clearSetAndCountSupportRuleTestPositions
  def test_clear_set_and_count_support_rule_test_positions
    red_king_square = Square.at(2, 2)
    white_man_square = Square.at(4, 4)
    board = Position.build({ red_king_square => Piece::RED_KING, white_man_square => "w" },
                           Side::RED)

    assert_equal Piece::RED_KING, board.at(red_king_square)
    assert_equal 1, board.count(Side::RED)
    assert_equal 1, board.count(Side::WHITE)

    emptied = board.place(red_king_square, nil)
    assert_nil emptied.at(red_king_square)
    assert_equal 0, emptied.count(Side::RED)
  end

  # Java: boardRejectsInvalidPlacementsAndSafelyReadsOutsideCoordinates
  def test_board_rejects_invalid_placements_and_safely_reads_outside_coordinates
    board = Position.start

    assert_nil board.at_coordinates(-1, 0)
    assert_nil board.at_coordinates(8, 0)
    assert_nil Square.at(0, 1), "a light square has no number, so nothing can be placed on it"
    assert_raises(Draughts::InvalidPosition) { Position.build({ 0 => "r" }, Side::RED) }
    assert_raises(Draughts::InvalidPosition) { Position.build({ 33 => "r" }, Side::RED) }
    assert_raises(Draughts::InvalidPosition) { board.place(nil, "r") }
    assert_raises(Draughts::InvalidPosition) { board.at(nil) }
    assert_raises(Draughts::InvalidPosition) { board.count(:nobody) }
  end

  # Java: resetRestoresOpeningAfterArbitraryMutation
  def test_reset_restores_opening_after_arbitrary_mutation
    changed = Position.start.place(Square.at(4, 4), Piece::RED_KING).place(1, nil)

    assert_equal Piece::RED_KING, changed.at_coordinates(4, 4)
    assert_equal 12, Position.start.count(Side::RED), "the opening position is a value, not state"
    assert_equal 12, Position.start.count(Side::WHITE)
    assert_nil Position.start.at_coordinates(4, 4)
    assert_equal "rrrrrrrrrrrr--------wwwwwwwwwwww", Position.start.board_string
  end
end
