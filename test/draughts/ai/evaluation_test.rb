# frozen_string_literal: true

require "minitest/autorun"
require "draughts"

# The static evaluation: material, advancement, and the endgame chase term.
#
# The reference weights are TASK-BRIEF.md section 2, "man 100 plus 2 per row advanced, king
# 130". They are marked tunable there, so these tests pin the shape of the function (level
# start, symmetry, more for a man that has come further, a king worth more than a man) and
# the exact numbers only where the brief states them.
class DraughtsAIEvaluationTest < Minitest::Test
  include Draughts

  Evaluation = Draughts::AI::Evaluation

  def test_the_starting_position_is_dead_level
    assert_equal 0, Evaluation.material(Position.start)
    assert_equal 0, Evaluation.evaluate(Position.start)
    assert_equal 0, Evaluation.evaluate(Position.start.with_side(Side::WHITE))
  end

  def test_a_man_is_a_hundred_plus_two_a_row_advanced
    # Square 1 is on row 0 and square 29 on row 7, so a Red man on 25 (row 6) has crossed
    # six rows. Red men never sit on row 7: landing there crowns them.
    assert_equal 100, Evaluation.material(Position.build({ 1 => "r" }, Side::RED))
    assert_equal 108, Evaluation.material(Position.build({ 17 => "r" }, Side::RED))
    assert_equal 112, Evaluation.material(Position.build({ 25 => "r" }, Side::RED))
    # White counts rows the other way: a White man on 29 (row 7) has crossed none.
    assert_equal(-100, Evaluation.material(Position.build({ 29 => "w" }, Side::RED)))
    assert_equal(-112, Evaluation.material(Position.build({ 8 => "w" }, Side::RED)))
  end

  def test_a_king_is_worth_a_hundred_and_thirty_wherever_it_stands
    [ 1, 8, 15, 22, 29 ].each do |square|
      assert_equal 130, Evaluation.material(Position.build({ square => "R" }, Side::RED))
      assert_equal(-130, Evaluation.material(Position.build({ square => "W" }, Side::RED)))
    end
  end

  def test_the_score_is_from_the_side_to_move
    board = { 11 => "r", 22 => "w", 9 => "r" }
    red = Position.build(board, Side::RED)
    white = Position.build(board, Side::WHITE)

    assert_equal Evaluation.evaluate(red), -Evaluation.evaluate(white)
    assert_operator Evaluation.evaluate(red), :>, 0
  end

  def test_the_evaluation_is_symmetric_under_mirroring_the_board_and_the_colours
    # Mirroring through the centre of the board sends PDN square n to 33 - n and swaps the
    # two sides, so the mirror of a position is worth what the original was, negated.
    random = Random.new(2026)
    mirror = { "r" => "w", "w" => "r", "R" => "W", "W" => "R" }
    120.times do
      pieces = {}
      (1..32).to_a.sample(random.rand(8) + 2, random: random).each do |square|
        pieces[square] = mirror.keys.sample(random: random)
      end
      side = random.rand(2).zero? ? Side::RED : Side::WHITE
      position = Position.build(pieces, side)
      flipped = Position.build(pieces.to_h { |square, char| [ 33 - square, mirror[char] ] },
                               Side.opponent(side))

      assert_equal Evaluation.material(position), -Evaluation.material(flipped)
      assert_equal Evaluation.evaluate(position), Evaluation.evaluate(flipped)
    end
  end

  def test_the_chase_term_sleeps_while_the_board_is_full_and_while_material_is_level
    assert_equal 0, Evaluation.chase(Position.start, 0)
    # Nine pieces, Red a king ahead: over the endgame threshold, so no chase.
    crowded = Position.build({ 1 => "R", 5 => "r", 9 => "r", 13 => "r", 17 => "r",
                               21 => "w", 25 => "w", 29 => "w", 30 => "w" }, Side::RED)

    assert_operator crowded.count, :>, Evaluation::ENDGAME_PIECES
    refute_equal 0, Evaluation.material(crowded)
    assert_equal 0, Evaluation.chase(crowded, Evaluation.material(crowded))
    # Level material: nobody is the leader, so nobody is chasing.
    level = Position.build({ 1 => "R", 29 => "W" }, Side::RED)

    assert_equal 0, Evaluation.material(level)
    assert_equal 0, Evaluation.chase(level, 0)
  end

  def test_the_chase_term_rewards_the_leader_for_closing_on_the_enemy
    far = Position.build({ 1 => "R", 5 => "R", 32 => "W" }, Side::RED)
    near = Position.build({ 28 => "R", 27 => "R", 32 => "W" }, Side::RED)

    assert_equal Evaluation.material(far), Evaluation.material(near)
    assert_operator Evaluation.evaluate(near), :>, Evaluation.evaluate(far)
    assert_operator Evaluation.chase(far, Evaluation.material(far)), :<, 0
  end

  # The bound the session-2 audit corrected (its finding M2). The claim this test used to
  # make, that the chase term is smaller than a man, is false: it can reach 147. What is
  # provable is CHASE_BOUND, and it is checked here three ways: by arithmetic, on the
  # position that attains it, and over a sample that includes the seed the audit found to
  # break the old assertion.
  def test_the_chase_term_never_exceeds_its_bound
    assert_equal 147, Evaluation::CHASE_BOUND
    assert_equal Evaluation::CHASE_VALUE * (Evaluation::ENDGAME_PIECES - 1) *
                 (Square::BOARD_SIZE - 1), Evaluation::CHASE_BOUND

    # Seven Red kings on the seven squares exactly seven steps from the White man on 4.
    worst = Position.parse("---wR-------R-------R-------RRRR r")

    assert_equal 8, worst.count
    assert_equal(-Evaluation::CHASE_BOUND, Evaluation.chase(worst, Evaluation.material(worst)),
                 "the bound must be attained, or it is not the bound")

    # Random.new(139) is the seed the audit used to fail the old assertion. Two facts are
    # asserted about the sample itself afterwards, so that the 900 bound checks cannot pass
    # by being vacuous: the term has to fire on most of these boards, and seed 139 has to
    # keep producing the counterexample that is the whole reason CHASE_BOUND is 147 and not
    # MAN_VALUE. Measured here: 632 of the 900 fire, and seed 139's counterexample is 114.
    fired = 0
    over_a_man = Hash.new(0)
    [ 7, 139, 4181 ].each do |seed|
      random = Random.new(seed)
      300.times do
        pieces = {}
        (1..32).to_a.sample(random.rand(6) + 2, random: random).each do |square|
          pieces[square] = %w[r R w W].sample(random: random)
        end
        position = Position.build(pieces, Side::RED)
        chase = Evaluation.chase(position, Evaluation.material(position))

        assert_operator chase.abs, :<=, Evaluation::CHASE_BOUND, position.key
        fired += 1 unless chase.zero?
        over_a_man[seed] += 1 if chase.abs > Evaluation::MAN_VALUE
      end
    end

    assert_operator fired, :>, 300, "the sample must exercise the term, not just count zeroes"
    assert_operator over_a_man[139], :>, 0,
                    "Random.new(139) is the audit's counterexample: chase can beat a man"
  end

  def test_one_king_can_never_chase_by_more_than_a_quarter_of_a_man
    # The per-king part of the bound, which is the property that makes the term safe in
    # practice: it breaks ties, it does not buy pieces.
    per_king = Evaluation::CHASE_VALUE * (Square::BOARD_SIZE - 1)

    assert_equal 21, per_king
    assert_operator per_king * 4, :<, Evaluation::MAN_VALUE
    random = Random.new(11)
    200.times do
      squares = (1..32).to_a.sample(2, random: random)
      position = Position.build({ squares[0] => "R", squares[1] => "w" }, Side::RED)

      assert_operator Evaluation.chase(position, Evaluation.material(position)).abs,
                      :<=, per_king
    end
  end

  def test_the_chase_term_points_at_the_side_that_is_behind
    red_ahead = Position.build({ 1 => "R", 5 => "R", 32 => "W" }, Side::RED)
    white_ahead = Position.build({ 32 => "W", 28 => "W", 1 => "R" }, Side::RED)

    assert_operator Evaluation.chase(red_ahead, Evaluation.material(red_ahead)), :<, 0
    assert_operator Evaluation.chase(white_ahead, Evaluation.material(white_ahead)), :>, 0
  end

  def test_weights_reports_what_the_search_is_using
    weights = Evaluation.weights

    assert_equal Evaluation::MAN_VALUE, weights[:man]
    assert_equal Evaluation::ADVANCE_VALUE, weights[:advance]
    assert_equal Evaluation::KING_VALUE, weights[:king]
    assert_equal(Evaluation::CHASE_ON ? Evaluation::CHASE_VALUE : 0, weights[:chase])
  end

  def test_the_distance_table_is_the_number_of_king_steps_between_two_squares
    assert_equal 0, Evaluation::DISTANCE[1][1]
    assert_equal 1, Evaluation::DISTANCE[1][5]
    assert_equal 7, Evaluation::DISTANCE[1][32]
    (1..Square::COUNT).each do |from|
      (1..Square::COUNT).each do |to|
        assert_equal Evaluation::DISTANCE[from][to], Evaluation::DISTANCE[to][from]
      end
    end
  end
end
