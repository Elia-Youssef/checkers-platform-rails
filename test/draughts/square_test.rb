# frozen_string_literal: true

require "minitest/autorun"
require "draughts"

# PDN numbering and diagonal geometry. The numbering claim under test is the one pinned in
# TASK-BRIEF.md section 1.2: with column and row counted from Red's bottom-left corner
# starting at 0, the number of a playable square is 4 * row + (3 - column / 2) + 1.
class DraughtsSquareTest < Minitest::Test
  include Draughts

  def test_board_is_eight_by_eight_with_thirty_two_playable_squares
    assert_equal 8, Square::BOARD_SIZE
    assert_equal 32, Square::COUNT
    assert_equal (1..32).to_a, Square::ALL

    playable = (0...8).to_a.product((0...8).to_a).count { |col, row| Square.playable?(col, row) }
    assert_equal 32, playable
  end

  def test_only_dark_squares_are_playable_and_off_board_coordinates_are_neither
    assert Square.valid?(0, 0)
    assert Square.valid?(7, 7)
    refute Square.valid?(-1, 0)
    refute Square.valid?(8, 7)

    assert Square.playable?(0, 0), "(0, 0) is dark"
    assert Square.playable?(7, 7), "(7, 7) is dark"
    refute Square.playable?(0, 1), "(0, 1) is light"
    refute Square.playable?(8, 8), "off the board is not playable"
    assert_nil Square.at(0, 1)
    assert_nil Square.at(-1, 0)
  end

  # The whole numbering written out, one literal pair per square, so this checks the engine
  # against a table rather than against a second copy of its own formula. The table was taken
  # from the independent reference model (provided/source-notes/checkers-model.py, from_pdn),
  # not from Draughts::Square: square 1 is Red's near-right corner (column 6, row 0), the
  # numbers run right to left along each row and then row by row upward.
  COORDINATES = {
    1 => [ 6, 0 ], 2 => [ 4, 0 ], 3 => [ 2, 0 ], 4 => [ 0, 0 ],
    5 => [ 7, 1 ], 6 => [ 5, 1 ], 7 => [ 3, 1 ], 8 => [ 1, 1 ],
    9 => [ 6, 2 ], 10 => [ 4, 2 ], 11 => [ 2, 2 ], 12 => [ 0, 2 ],
    13 => [ 7, 3 ], 14 => [ 5, 3 ], 15 => [ 3, 3 ], 16 => [ 1, 3 ],
    17 => [ 6, 4 ], 18 => [ 4, 4 ], 19 => [ 2, 4 ], 20 => [ 0, 4 ],
    21 => [ 7, 5 ], 22 => [ 5, 5 ], 23 => [ 3, 5 ], 24 => [ 1, 5 ],
    25 => [ 6, 6 ], 26 => [ 4, 6 ], 27 => [ 2, 6 ], 28 => [ 0, 6 ],
    29 => [ 7, 7 ], 30 => [ 5, 7 ], 31 => [ 3, 7 ], 32 => [ 1, 7 ]
  }.freeze

  def test_every_square_number_has_its_pinned_coordinates
    assert_equal 32, COORDINATES.length
    assert_equal (1..32).to_a, COORDINATES.keys

    COORDINATES.each do |number, (col, row)|
      assert_equal [ col, row ], Square.coordinates(number), "square #{number}"
      assert_equal col, Square.column(number), "column of square #{number}"
      assert_equal row, Square.row(number), "row of square #{number}"
      assert_equal number, Square.number(col, row), "number at column #{col}, row #{row}"
      assert_equal number, Square.at(col, row)
    end

    assert_equal 32, COORDINATES.values.uniq.length, "no two squares share a coordinate"
  end

  def test_every_playable_coordinate_has_a_number_and_every_light_one_has_none
    numbered = {}
    (0...8).each do |row|
      (0...8).each do |col|
        number = Square.at(col, row)
        if (col + row).even?
          refute_nil number, "column #{col}, row #{row} is dark and must be numbered"
          numbered[number] = [ col, row ]
        else
          assert_nil number, "column #{col}, row #{row} is light"
        end
      end
    end

    assert_equal COORDINATES, numbered
  end

  def test_numbers_and_coordinates_invert_for_all_thirty_two_squares
    seen = []
    (1..32).each do |number|
      col, row = Square.coordinates(number)
      assert Square.playable?(col, row), "square #{number} must be playable"
      assert_equal number, Square.number(col, row)
      seen << [ col, row ]
    end
    assert_equal 32, seen.uniq.length
  end

  # The three squares the brief and the reference model name by hand.
  def test_the_three_anchor_squares_of_the_numbering
    assert_equal [ 6, 0 ], Square.coordinates(1), "square 1 is Red's near-right corner"
    assert_equal [ 0, 0 ], Square.coordinates(4)
    assert_equal [ 1, 7 ], Square.coordinates(32)
    assert_equal (1..4).to_a, (1..32).select { |number| Square.row(number).zero? }
    assert_equal (29..32).to_a, (1..32).select { |number| Square.row(number) == 7 }
  end

  def test_promotion_rows_are_row_seven_for_red_and_row_zero_for_white
    assert_equal 7, Square.promotion_row(Side::RED)
    assert_equal 0, Square.promotion_row(Side::WHITE)
    assert_equal (29..32).to_a, (1..32).select { |number| Square.promotion?(number, Side::RED) }
    assert_equal (1..4).to_a, (1..32).select { |number| Square.promotion?(number, Side::WHITE) }
  end

  def test_men_use_two_directions_and_kings_use_four
    assert_equal 2, Square.directions(Side::RED, false).length
    assert_equal 2, Square.directions(Side::WHITE, false).length
    assert_equal 4, Square.directions(Side::RED, true).length
    assert_equal Square::KING_DIRECTIONS, Square.directions(Side::WHITE, true)

    Square.directions(Side::RED, false).each do |direction|
      assert_equal 1, Square::DIRECTIONS[direction][1], "Red men move toward row 7"
    end
    Square.directions(Side::WHITE, false).each do |direction|
      assert_equal(-1, Square::DIRECTIONS[direction][1], "White men move toward row 0")
    end
  end

  def test_steps_are_adjacent_and_jumps_land_two_squares_away_over_the_step
    (1..32).each do |number|
      col, row = Square.coordinates(number)
      Square::KING_DIRECTIONS.each do |direction|
        dcol, drow = Square::DIRECTIONS[direction]
        step = Square.step(number, direction)
        expected_step = Square.at(col + dcol, row + drow)
        if expected_step.nil?
          assert_nil step
        else
          assert_equal expected_step, step
        end

        jump = Square.jump(number, direction)
        if jump.nil?
          assert_nil Square.at(col + 2 * dcol, row + 2 * drow)
        else
          over, landing = jump
          assert_equal step, over, "a jump goes over its own step"
          assert_equal Square.at(col + 2 * dcol, row + 2 * drow), landing
          assert_equal over, Square.midpoint(number, landing)
        end
      end
    end
  end

  def test_midpoint_is_nil_for_squares_that_are_not_a_jump_apart
    assert_nil Square.midpoint(11, 15), "adjacent squares are a step, not a jump"
    assert_nil Square.midpoint(11, 11)
    assert_equal 15, Square.midpoint(11, 18)
  end

  def test_square_numbers_outside_one_to_thirty_two_are_refused
    assert_raises(Draughts::InvalidPosition) { Square.check_number(0) }
    assert_raises(Draughts::InvalidPosition) { Square.check_number(33) }
    assert_raises(Draughts::InvalidPosition) { Square.check_number(nil) }
    assert_raises(Draughts::InvalidPosition) { Square.row("11") }
    assert_raises(Draughts::InvalidPosition) { Square.number(0, 1) }
    refute Square.number?(0)
    assert Square.number?(32)
  end
end
