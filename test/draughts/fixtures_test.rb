# frozen_string_literal: true

require "minitest/autorun"
require "draughts"

# The fixtures F1 to F7b of CONCEPT.md section 4.3, with the expected move lists taken
# verbatim from provided/source-notes/checkers-model-output.txt. Squares are PDN numbers.
class DraughtsFixturesTest < Minitest::Test
  include Draughts

  # F7: the 80 half moves of the kings-only walk printed in checkers-model-output.txt,
  # copied line for line. Red kings start on 4 and 1, White kings on 32 and 29, Red to move.
  FORTY_MOVE_WALK = %w[
    1-6 32-27 6-9 27-23 9-6 23-18 6-1 18-23 4-8 23-18 8-12 18-23 1-5 23-26 5-9 26-23
    12-8 23-19 9-14 19-24 14-10 29-25 10-14 24-27 8-4 27-32 4-8 32-28 8-4 25-30 14-18 28-32
    4-8 32-28 8-12 28-24 12-8 24-20 18-14 30-26 8-3 26-31 14-18 20-16 18-14 31-26 14-9 26-31
    9-6 31-26 6-2 26-22 2-6 16-19 6-9 19-23 3-7 22-25 7-11 23-26 11-8 26-30 9-5 25-22
    8-3 30-25 3-8 25-21 5-1 22-17 1-5 21-25 8-3 25-22 3-7 17-21 7-2 22-17 5-1 21-25
  ].freeze

  # F1 mandatory capture: legal moves == ["11x18"] (quiet 4-8, 11-16 refused)
  def test_f1_mandatory_capture
    position = Position.build({ 11 => "r", 4 => "r", 15 => "w" }, Side::RED)

    assert_equal [ "11x18" ], pdn(position)
    refute_includes pdn(position), "4-8"
    refute_includes pdn(position), "11-16"
  end

  # F2 double jump: legal moves == ["4x11x18"], two captured squares
  # F2 after the jump: White has no pieces, Red wins by no_pieces
  def test_f2_double_jump_and_the_win_by_no_pieces
    position = Position.build({ 4 => "r", 8 => "w", 15 => "w" }, Side::RED)
    moves = Rules.legal_moves(position)

    assert_equal [ "4x11x18" ], moves.map(&:pdn)
    assert_equal 2, moves.first.capture_count

    game = Game.new(position)
    game.play(moves.first)
    assert_equal :red_won, game.result
    assert_equal :no_pieces, game.reason
    assert_equal 0, game.position.count(Side::WHITE)
  end

  # F3 promotion ends the jump: legal moves == ["24x31"] (not 24x31x22)
  # F3 the mover is promoted, it is White to move, White man 26 is still on the board
  def test_f3_promotion_ends_the_jump
    position = Position.build({ 24 => "r", 27 => "w", 26 => "w" }, Side::RED)
    moves = Rules.legal_moves(position)

    assert_equal [ "24x31" ], moves.map(&:pdn)
    refute_includes moves.map(&:pdn), "24x31x22"

    game = Game.new(position)
    move = game.play("24x31")
    assert move.promotion?
    assert_equal Side::WHITE, game.side_to_move
    assert_equal Piece::RED_KING, game.position.at(31)
    assert_equal Piece::WHITE_MAN, game.position.at(26)
    assert_nil game.result
  end

  # F4 king moves == ["15-10","15-11","15-18","15-19"]
  def test_f4_king_mobility
    position = Position.build({ 15 => "R", 29 => "W" }, Side::RED)

    assert_equal [ "15-10", "15-11", "15-18", "15-19" ], pdn(position)
  end

  # F4b king backward capture: legal moves == ["15x8"]
  def test_f4b_king_captures_backward
    position = Position.build({ 15 => "R", 11 => "w", 29 => "W" }, Side::RED)

    assert_equal [ "15x8" ], pdn(position)
  end

  # F4c man never captures backward: legal moves == ["15-18","15-19"]
  def test_f4c_a_man_never_captures_backward
    position = Position.build({ 15 => "r", 11 => "w", 29 => "W" }, Side::RED)

    assert_equal [ "15-18", "15-19" ], pdn(position)
  end

  # F5 White to move with no legal move: result == (Red, no_moves)
  def test_f5_no_legal_move_loses
    position = Position.build({ 32 => "w", 28 => "r", 27 => "r", 23 => "r" }, Side::WHITE)
    game = Game.new(position)

    assert_empty Rules.legal_moves(position)
    assert_equal :red_won, game.result
    assert_equal :no_moves, game.reason
    assert_equal 1, game.position.count(Side::WHITE), "White still has a piece, it just cannot move"
  end

  # F6 threefold: no result through ply 7, draw by threefold_repetition on ply 8
  def test_f6_threefold_repetition_draws_on_ply_eight
    game = Game.new(Position.build({ 4 => "R", 29 => "W" }, Side::RED))
    cycle = [ "4-8", "29-25", "8-4", "25-29" ]
    results = []

    8.times do |ply|
      game.play(cycle[ply % 4])
      results << game.result
    end

    assert_equal [ nil ] * 7, results.first(7), "no result through ply 7"
    assert_equal :draw, game.result
    assert_equal :threefold_repetition, game.reason
    assert_equal 8, game.plies
    assert_equal 3, game.occurrence_count, "the start counted as the first occurrence"
  end

  # F7 forty-move rule: the printed kings-only walk reaches the draw on exactly ply 80 with
  # quiet_plies == 80, and not at ply 79.
  def test_f7_the_forty_move_rule_fires_at_exactly_eighty_quiet_plies
    game = Game.new(forty_move_start)

    assert_equal 80, FORTY_MOVE_WALK.length

    FORTY_MOVE_WALK.each_with_index do |text, index|
      ply = index + 1
      if ply == 80
        assert_nil game.result, "the game must still be running at ply 79"
        assert_equal 79, game.quiet_plies
      end
      game.play(text)
      assert_nil game.result, "unexpected result at ply #{ply}" if ply < 80
      assert_equal ply, game.quiet_plies, "every ply of this walk is a quiet king move"
    end

    assert_equal :draw, game.result
    assert_equal :forty_move_rule, game.reason
    assert_equal 80, game.plies
    assert_equal 80, game.quiet_plies
  end

  def test_f7_the_walk_is_capture_free_repetition_free_and_kings_only
    game = Game.new(forty_move_start)
    FORTY_MOVE_WALK.each { |text| game.play(text) }

    assert_empty game.moves.select(&:capture?)
    assert_empty game.moves.select(&:promotion?)
    assert_equal 2, game.position.count(Side::RED)
    assert_equal 2, game.position.count(Side::WHITE)
    assert_equal 4, game.position.count_kings(Side::RED) + game.position.count_kings(Side::WHITE)
    assert_operator game.occurrences.values.max, :<, 3,
                    "the forty-move rule fired first, so no position occurred three times"
  end

  # F7b a man move after 79 quiet plies resets the counter to 0 and the game continues
  def test_f7b_a_man_move_resets_the_quiet_ply_counter
    game = Game.new(Position.build({ 4 => "R", 29 => "W", 13 => "r" }, Side::RED))
    game.quiet_plies = 79

    assert_nil game.result
    game.play("13-17")

    assert_nil game.result
    assert_equal 0, game.quiet_plies
  end

  def test_f7b_a_capture_also_resets_the_quiet_ply_counter
    game = Game.new(Position.build({ 15 => "R", 19 => "w", 29 => "W" }, Side::RED))
    game.quiet_plies = 79

    assert_equal [ "15x24" ], game.legal_moves.map(&:pdn)
    game.play("15x24")

    assert_nil game.result
    assert_equal 0, game.quiet_plies
  end

  def test_a_promotion_move_counts_as_a_man_move_and_resets_the_counter
    game = Game.new(Position.build({ 27 => "r", 1 => "W", 5 => "W" }, Side::RED))
    game.quiet_plies = 79

    move = game.play("27-32")
    assert move.promotion?
    assert_nil game.result
    assert_equal 0, game.quiet_plies
  end

  private

  def pdn(position)
    Rules.legal_moves(position).map(&:pdn)
  end

  def forty_move_start
    Position.build({ 4 => "R", 1 => "R", 32 => "W", 29 => "W" }, Side::RED)
  end
end
