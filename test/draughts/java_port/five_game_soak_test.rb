# frozen_string_literal: true

require "minitest/autorun"
require "draughts"

# Port of provided/source-libgdx/model/test/FiveGameSoakTest.java (1 case): five complete
# games played through the same leg-by-leg interface the web request uses, with a seeded
# random source, checking that nothing leaks from one game to the next.
#
# What changed in the port and why: the Java version drove GameState.clickSquare and stopped
# at a 10,000 turn cap because that model had no draw rules, so a game could in principle
# shuffle forever. This engine has both draw rules, so every game reaches a result; the cap
# is kept only as a guard and the test asserts it is never reached.
class JavaPortFiveGameSoakTest < Minitest::Test
  include Draughts

  GAME_COUNT = 5
  PLY_CAP = 400
  SEED = 0x5EEDC0DE

  # Java: fiveCompleteGamesResetAndFinishWithoutStateLeakage
  def test_five_complete_games_reset_and_finish_without_state_leakage
    random = Random.new(SEED)
    reasons = Hash.new(0)

    GAME_COUNT.times do |index|
      game = Game.new
      assert_opening_state(game)

      plies = 0
      while !game.finished? && plies < PLY_CAP
        moves = game.legal_moves
        refute_empty moves, "a side that is not finished must have a move"

        chosen = moves[random.rand(moves.length)]
        result = game.play_leg(chosen.origin, chosen.landings.first)
        until result.complete?
          assert game.pending?, "an unfinished sequence must be pending"
          targets = game.legal_targets(game.locked_square)
          refute_empty targets, "a forced jump must offer a continuation"
          result = game.play_leg(game.locked_square, targets[random.rand(targets.length)])
        end

        plies += 1
        assert_equal plies, game.plies
        refute game.pending?
      end

      refute game.pending?
      refute_nil game.result, "game #{index + 1} did not finish"
      assert_operator plies, :<, PLY_CAP
      assert_includes Game::RESULTS, game.result
      assert_includes Game::REASONS, game.reason
      assert_equal game.plies, game.moves.length
      reasons[game.reason] += 1
    end

    assert_equal GAME_COUNT, reasons.values.sum
    assert_opening_state(Game.new)
    assert_equal "rrrrrrrrrrrr--------wwwwwwwwwwww r", Position.start.key
  end

  private

  def assert_opening_state(game)
    assert_equal 12, game.position.count(Side::RED)
    assert_equal 12, game.position.count(Side::WHITE)
    assert_equal Side::RED, game.side_to_move
    assert_equal 0, game.plies
    assert_equal 0, game.quiet_plies
    assert_empty game.moves
    assert_nil game.result
    assert_nil game.pending_path
    assert_equal 7, game.legal_moves.length
  end
end
