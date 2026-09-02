# frozen_string_literal: true

require "minitest/autorun"
require "draughts"

# The three grader-reproducible opening lines of
# provided/source-notes/checkers-model-lines.txt, played from the standard start. Each line
# is a sequence of PDN moves anyone can replay by hand, and the assertion is the legal move
# list the reference model printed for the position it reaches.
class DraughtsLinesTest < Minitest::Test
  include Draughts

  # A. after 11-15 22-18, Red legal moves: ["15x22"]
  def test_line_a_mandatory_capture
    game = play("11-15", "22-18")

    assert_equal [ "15x22" ], game.legal_moves.map(&:pdn)
    assert_equal Side::RED, game.side_to_move
    assert_equal 2, game.plies
  end

  # B. shallowest multi-jump: after 5 plies 12-16 24-20 8-12 28-24 16-19
  #    White to move, legal moves: ["23x16", "24x15x8"]
  def test_line_b_the_shallowest_multi_jump
    game = play("12-16", "24-20", "8-12", "28-24", "16-19")

    assert_equal Side::WHITE, game.side_to_move
    assert_equal [ "23x16", "24x15x8" ], game.legal_moves.map(&:pdn).sort
    assert_equal 5, game.plies
  end

  # B, leg by leg: after the leg 24 to 15 the sequence is locked to the jumping piece, only
  # square 8 is offered, no other piece may move, and finishing records one move 24x15x8.
  def test_line_b_locks_the_sequence_after_the_first_leg
    game = play("12-16", "24-20", "8-12", "28-24", "16-19")

    result = game.play_leg(24, 15)
    refute result.complete?
    assert game.pending?
    assert_equal [ 24, 15 ], game.pending_path
    assert_equal 15, game.locked_square
    assert_equal [ "24x15x8" ], game.legal_moves.map(&:pdn),
                 "while a path is pending the only legal move is its own continuation"
    assert_equal({ 15 => [ 8 ] }, game.targets_by_square)
    assert_equal [ 8 ], game.legal_targets(15)
    assert_equal [], game.legal_targets(23), "the other jumping piece is locked out"
    assert_equal [], game.legal_targets(20)
    assert_equal 5, game.plies, "nothing is recorded until the sequence ends"
    assert_equal Side::WHITE, game.side_to_move
    assert_raises(Draughts::IllegalMove) { game.play_leg(23, 16) }
    assert_raises(Draughts::IllegalMove) { game.play_leg(15, 19) }
    assert_raises(Draughts::IllegalMove) { game.play("23x16") }

    finished = game.play_leg(15, 8)
    assert finished.complete?
    assert_equal "24x15x8", finished.move.pdn
    assert_equal [ 19, 11 ], finished.move.captures
    assert_equal 6, game.plies
    assert_equal "24x15x8", game.last_move.pdn
    assert_equal Side::RED, game.side_to_move
    refute game.pending?
  end

  # C. shortest sampled promotion-during-jump: after 7 plies
  #    11-16 23-18 9-14 18x9 6x13 24-20 2-6
  #    position r-rrrrrr-r-rr--r---www--wwwwwwww w; the promoting capture is 20x11x2;
  #    legal moves then: ["20x11x2"]
  def test_line_c_promotion_during_a_jump_ends_the_move
    game = play("11-16", "23-18", "9-14", "18x9", "6x13", "24-20", "2-6")

    assert_equal "r-rrrrrr-r-rr--r---www--wwwwwwww w", game.position.key
    assert_equal [ "20x11x2" ], game.legal_moves.map(&:pdn)

    move = game.legal_moves.first
    assert move.promotion?
    assert_equal [ 16, 7 ], move.captures
    game.play(move)

    assert_equal Piece::WHITE_KING, game.position.at(2)
    assert_equal Side::RED, game.side_to_move, "the new king does not jump on"
    assert_equal 8, game.plies
  end

  def test_line_c_the_new_king_could_have_jumped_on_if_the_rule_allowed_it
    game = play("11-16", "23-18", "9-14", "18x9", "6x13", "24-20", "2-6")
    game.play("20x11x2")

    # The White king now stands on 2 with a Red man on 6 and square 9 empty: had promotion
    # not ended the move, 2x9 was there to be played.
    assert_equal Piece::RED_MAN, game.position.at(6)
    assert game.position.empty?(9)
    white_to_move = game.position.with_side(Side::WHITE)
    jump_on = Rules.legal_moves(white_to_move).find { |move| move.origin == 2 }
    refute_nil jump_on, "the new king had a jump waiting for it"
    assert jump_on.capture?
    assert_equal 9, jump_on.landings.first
  end

  private

  def play(*texts)
    game = Game.new
    texts.each { |text| game.play(text) }
    game
  end
end
