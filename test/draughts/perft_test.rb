# frozen_string_literal: true

require "minitest/autorun"
require "draughts"

# perft: how many distinct move sequences of a given length exist from the starting
# position, with a complete jump sequence counted as one node and promotion ending the move.
# The five shallow numbers are asserted literally on every run; depths 6 and 7 are slow, so
# they run only with DRAUGHTS_SLOW=1 in the environment.
class DraughtsPerftTest < Minitest::Test
  include Draughts

  def test_perft_one_to_five_from_the_starting_position
    assert_equal 7, Perft.count(Position.start, 1)
    assert_equal 49, Perft.count(Position.start, 2)
    assert_equal 302, Perft.count(Position.start, 3)
    assert_equal 1469, Perft.count(Position.start, 4)
    assert_equal 7361, Perft.count(Position.start, 5)
  end

  def test_perft_six_and_seven_from_the_starting_position
    skip "set DRAUGHTS_SLOW=1 to run perft 6 and 7" unless ENV["DRAUGHTS_SLOW"] == "1"

    assert_equal 36_768, Perft.count(Position.start, 6)
    assert_equal 179_740, Perft.count(Position.start, 7)
  end

  def test_depth_zero_is_the_position_itself_and_depth_one_is_the_move_count
    assert_equal 1, Perft.count(Position.start, 0)
    assert_equal Rules.legal_moves(Position.start).length, Perft.count(Position.start, 1)
    assert_raises(Draughts::InvalidPosition) { Perft.count(Position.start, -1) }
  end

  def test_divide_splits_a_depth_over_the_moves_and_sums_back_to_it
    divided = Perft.divide(Position.start, 4)

    assert_equal %w[9-13 9-14 10-14 10-15 11-15 11-16 12-16], divided.keys
    assert_equal 1469, divided.values.sum
    assert_equal 302, Perft.divide(Position.start, 3).values.sum
    assert_raises(Draughts::InvalidPosition) { Perft.divide(Position.start, 0) }
  end

  # A terminal position has no moves at all, at any depth.
  def test_perft_of_a_finished_position_is_zero
    position = Position.build({ 32 => "w", 28 => "r", 27 => "r", 23 => "r" }, Side::WHITE)

    assert_equal 0, Perft.count(position, 1)
    assert_equal 0, Perft.count(position, 3)
  end

  # The convention the published numbers assume, stated as two assertions.
  def test_a_multi_jump_counts_as_one_node_and_promotion_ends_the_move
    double_jump = Position.build({ 4 => "r", 8 => "w", 15 => "w" }, Side::RED)
    assert_equal 1, Perft.count(double_jump, 1), "two jumps, one node"

    promoting = Position.build({ 24 => "r", 27 => "w", 26 => "w" }, Side::RED)
    assert_equal 1, Perft.count(promoting, 1)
    assert_equal [ "24x31" ], Rules.legal_moves(promoting).map(&:pdn)
  end
end
