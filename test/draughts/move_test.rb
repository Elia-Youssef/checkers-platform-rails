# frozen_string_literal: true

require "minitest/autorun"
require "draughts"

# One complete move, and its PDN text. A quiet move is written from-to, a jump lists every
# landing square joined by x (TASK-BRIEF.md section 1.2).
class DraughtsMoveTest < Minitest::Test
  include Draughts

  def test_a_quiet_move_is_written_from_to
    move = Move.new(origin: 11, landings: [ 15 ])

    assert_equal "11-15", move.pdn
    assert_equal "11-15", move.to_s
    assert_equal 11, move.origin
    assert_equal 15, move.destination
    assert_equal [ 11, 15 ], move.squares
    refute move.capture?
    refute move.promotion?
    assert_equal 0, move.capture_count
    assert_equal 1, move.leg_count
  end

  def test_a_single_capture_is_written_with_one_x
    move = Move.new(origin: 15, landings: [ 22 ], captures: [ 18 ])

    assert_equal "15x22", move.pdn
    assert move.capture?
    assert_equal [ 18 ], move.captures
    assert_equal 1, move.capture_count
  end

  def test_a_multi_jump_is_one_move_that_lists_every_landing_square
    move = Move.new(origin: 24, landings: [ 15, 8 ], captures: [ 20, 11 ])

    assert_equal "24x15x8", move.pdn
    assert_equal 8, move.destination
    assert_equal [ 24, 15, 8 ], move.squares
    assert_equal 2, move.capture_count
    assert_equal 2, move.leg_count
  end

  def test_a_promotion_flag_travels_with_the_move
    quiet = Move.new(origin: 27, landings: [ 32 ], promotion: true)
    jump = Move.new(origin: 24, landings: [ 31 ], captures: [ 27 ], promotion: true)

    assert quiet.promotion?
    assert jump.promotion?
    assert_equal "27-32", quiet.pdn
    assert_equal "24x31", jump.pdn
    assert_includes jump.inspect, "promotion"
  end

  def test_moves_are_frozen_values_compared_by_their_parts
    one = Move.new(origin: 24, landings: [ 15, 8 ], captures: [ 20, 11 ])
    same = Move.new(origin: 24, landings: [ 15, 8 ], captures: [ 20, 11 ])
    other = Move.new(origin: 24, landings: [ 15 ], captures: [ 20 ])

    assert_equal one, same
    assert_equal one.hash, same.hash
    refute_equal one, other
    assert one.frozen?
    assert one.landings.frozen?
    assert one.captures.frozen?
  end

  def test_a_move_needs_a_real_origin_and_at_least_one_landing_square
    assert_raises(Draughts::InvalidPosition) { Move.new(origin: nil, landings: [ 15 ]) }
    assert_raises(Draughts::InvalidPosition) { Move.new(origin: 11, landings: []) }
    assert_raises(Draughts::InvalidPosition) { Move.new(origin: 11, landings: [ 33 ]) }
    assert_raises(Draughts::InvalidPosition) { Move.new(origin: 0, landings: [ 15 ]) }
    assert_raises(Draughts::InvalidPosition) do
      Move.new(origin: 24, landings: [ 15, 8 ], captures: [ 20 ])
    end
  end
end
