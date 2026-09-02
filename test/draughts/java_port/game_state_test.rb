# frozen_string_literal: true

require "minitest/autorun"
require "draughts"

# Port of provided/source-libgdx/model/test/GameStateTest.java (14 cases). Each test keeps
# its Java name and its coordinates, written through Draughts::Square.at(column, row).
#
# What changed in the port and why: the Java GameState owned both the game and the click
# state (selected square, forced jump, selected moves) because it was the desktop screen's
# model. The rules engine here owns the game and the pending jump path; which square a
# player has selected is presentation, so it lives in ClickSession below, a test double for
# the Rails controller and view. ClickSession contains no rule of draughts: every legality
# question goes to Draughts::Game.
#
# The other deliberate difference is when a jumped piece leaves the board. The Java model
# removed it as soon as its leg was played. The rules say it stays until the whole move
# ends, so the engine keeps it and Game#display_position is what shows the board part way
# through a sequence, with the pieces taken so far already gone. That is the board these
# tests read.
class ClickSession
  attr_reader :game, :selected

  def initialize(game = Draughts::Game.new)
    @game = game
    @selected = nil
  end

  # One click on a board square, by column and row, exactly like the desktop version:
  # a destination of the current selection plays that leg; while a jump sequence is pending
  # nothing else is accepted; one of your own pieces selects or re-selects; anything else
  # clears the selection.
  def click(col, row)
    return self if @game.finished?

    square = Draughts::Square.at(col, row)
    if square && @selected && destinations.include?(square)
      result = @game.play_leg(@selected, square)
      @selected = result.complete? ? nil : @game.locked_square
      return self
    end
    return self if @game.pending?

    @selected = if square && @game.position.side_at(square) == @game.side_to_move
                  square
    end
    self
  end

  def destinations
    @selected ? @game.legal_targets(@selected) : []
  end

  def board
    @game.display_position
  end

  def turn
    @game.side_to_move
  end

  def forced_jump
    @game.locked_square
  end

  def winner
    @game.winner
  end
end

class JavaPortGameStateTest < Minitest::Test
  include Draughts

  def setup
    @session = ClickSession.new
  end

  # Java: newGameHasTheCompleteRedOpeningState
  def test_new_game_has_the_complete_red_opening_state
    assert_equal 12, board.count(Side::RED)
    assert_equal 12, board.count(Side::WHITE)
    assert_equal Side::RED, @session.turn
    assert_nil @session.selected
    assert_nil @session.forced_jump
    assert_nil @session.winner
    assert_empty @session.destinations
  end

  # Java: clicksSelectReselectAndClearOwnPieces
  def test_clicks_select_reselect_and_clear_own_pieces
    @session.click(0, 2)
    assert_equal Square.at(0, 2), @session.selected
    assert_equal [ Square.at(1, 3) ], @session.destinations

    @session.click(2, 2)
    assert_equal Square.at(2, 2), @session.selected
    assert_equal [ Square.at(1, 3), Square.at(3, 3) ].sort, @session.destinations.sort

    @session.click(7, 7)
    assert_nil @session.selected
    assert_empty @session.destinations
  end

  # Java: clickOutsideBoardClearsSelectionWithoutMoving
  def test_click_outside_board_clears_selection_without_moving
    @session.click(0, 2)
    @session.click(-1, 3)

    assert_nil @session.selected
    assert_equal 12, board.count(Side::RED)
    assert_equal Side::RED, @session.turn
  end

  # Java: legalSimpleMoveUpdatesBoardAndAlternatesTurn
  def test_legal_simple_move_updates_board_and_alternates_turn
    @session.click(0, 2)
    @session.click(1, 3)

    assert_nil board.at_coordinates(0, 2)
    assert_equal Piece::RED_MAN, board.at_coordinates(1, 3)
    assert_equal Side::WHITE, @session.turn
    assert_nil @session.selected
    assert_nil @session.forced_jump
    assert_equal [ "12-16" ], @session.game.moves.map(&:pdn)
  end

  # Java: anUnselectedOrIllegalDestinationDoesNotMoveAPiece
  def test_an_unselected_or_illegal_destination_does_not_move_a_piece
    @session.click(1, 3)
    assert_equal Side::RED, @session.turn
    assert_equal 12, board.count(Side::RED)

    @session.click(0, 2)
    @session.click(3, 3)
    assert_equal Side::RED, @session.turn
    assert_equal Piece::RED_MAN, board.at_coordinates(0, 2)
    assert_equal 0, @session.game.plies
  end

  # Java: mandatoryCapturePreventsSelectingASimpleMoveForAnotherPiece
  def test_mandatory_capture_prevents_selecting_a_simple_move_for_another_piece
    @session = session_for({ Square.at(0, 2) => "r", Square.at(2, 2) => "r",
                             Square.at(3, 3) => "w" }, Side::RED)

    @session.click(0, 2)
    assert_equal Square.at(0, 2), @session.selected
    assert_empty @session.destinations

    @session.click(1, 3)
    assert_equal Piece::RED_MAN, board.at_coordinates(0, 2)
    assert_equal Side::RED, @session.turn
    assert_equal 0, @session.game.plies
  end

  # Java: captureRemovesImmediatelyAndLocksAForcedChainToTheSamePiece
  def test_capture_removes_immediately_and_locks_a_forced_chain_to_the_same_piece
    @session = session_for({ Square.at(0, 0) => "r", Square.at(6, 0) => "r",
                             Square.at(1, 1) => "w", Square.at(3, 3) => "w",
                             Square.at(7, 1) => "w" }, Side::RED)

    @session.click(0, 0)
    @session.click(2, 2)

    assert_nil board.at_coordinates(1, 1), "the piece taken so far is shown gone"
    assert_equal Piece::RED_MAN, board.at_coordinates(2, 2)
    assert_equal Side::RED, @session.turn
    assert_equal Square.at(2, 2), @session.selected
    assert_equal Square.at(2, 2), @session.forced_jump
    assert_equal [ Square.at(4, 4) ], @session.destinations
    assert_equal 0, @session.game.plies, "one move is recorded, and only when it ends"
    assert_equal Piece::WHITE_MAN, @session.game.position.at_coordinates(1, 1),
                 "the stored position still holds every jumped piece"

    @session.click(6, 0)
    @session.click(5, 1)
    assert_equal Square.at(2, 2), @session.selected, "the lock ignores every other piece"
    assert_equal Square.at(2, 2), @session.forced_jump
    assert_equal Piece::RED_MAN, board.at_coordinates(2, 2)

    @session.click(4, 4)
    assert_nil board.at_coordinates(3, 3)
    assert_equal Piece::RED_MAN, board.at_coordinates(4, 4)
    assert_equal Side::WHITE, @session.turn
    assert_nil @session.selected
    assert_nil @session.forced_jump
    assert_equal [ "4x11x18" ], @session.game.moves.map(&:pdn), "the sequence is one move"
    assert_equal :red_won, @session.game.result, "the last White man has no move left"
    assert_equal :no_moves, @session.game.reason
  end

  # Java: forcedChainOffersEveryAvailableNextCapture
  def test_forced_chain_offers_every_available_next_capture
    @session = session_for({ Square.at(2, 0) => "r", Square.at(3, 1) => "w",
                             Square.at(3, 3) => "w", Square.at(5, 3) => "w" }, Side::RED)

    @session.click(2, 0)
    @session.click(4, 2)

    assert_equal [ Square.at(2, 4), Square.at(6, 4) ].sort, @session.destinations.sort
    assert_equal [ "3x10x17", "3x10x19" ], @session.game.legal_moves.map(&:pdn).sort
  end

  # Java: simpleMovePromotesARedManOnRowSeven
  def test_simple_move_promotes_a_red_man_on_row_seven
    @session = session_for({ Square.at(2, 6) => "r", Square.at(0, 6) => "w" }, Side::RED)

    @session.click(2, 6)
    @session.click(1, 7)

    assert_equal Piece::RED_KING, board.at_coordinates(1, 7)
    assert_equal Side::WHITE, @session.turn
    assert @session.game.last_move.promotion?
  end

  # Java: capturePromotionEndsTheChainEvenWhenTheNewKingCouldJump
  def test_capture_promotion_ends_the_chain_even_when_the_new_king_could_jump
    @session = session_for({ Square.at(1, 5) => "r", Square.at(2, 6) => "w",
                             Square.at(4, 6) => "w" }, Side::RED)

    @session.click(1, 5)
    @session.click(3, 7)

    assert_equal Piece::RED_KING, board.at_coordinates(3, 7)
    assert_nil board.at_coordinates(2, 6)
    assert_equal Piece::WHITE_MAN, board.at_coordinates(4, 6), "the second man survives"
    assert_equal Side::WHITE, @session.turn
    assert_nil @session.forced_jump
    assert_nil @session.selected
    assert_nil @session.winner
    assert_equal [ "24x31" ], @session.game.moves.map(&:pdn)
  end

  # Java: whitePromotesOnRowZero
  def test_white_promotes_on_row_zero
    @session = session_for({ Square.at(1, 1) => "w", Square.at(6, 6) => "r" }, Side::WHITE)

    @session.click(1, 1)
    @session.click(0, 0)

    assert_equal Piece::WHITE_KING, board.at_coordinates(0, 0)
    assert_equal Side::RED, @session.turn
  end

  # Java: takingTheLastOpponentPieceWinsAndWinnerStateIgnoresClicks
  def test_taking_the_last_opponent_piece_wins_and_winner_state_ignores_clicks
    @session = session_for({ Square.at(0, 0) => "r", Square.at(1, 1) => "w" }, Side::RED)

    @session.click(0, 0)
    @session.click(2, 2)

    assert_equal Side::RED, @session.winner
    assert_equal :red_won, @session.game.result
    assert_equal :no_pieces, @session.game.reason
    assert_equal 0, board.count(Side::WHITE)
    assert_equal Side::WHITE, @session.turn

    @session.click(2, 2)
    @session.click(3, 3)
    assert_equal Piece::RED_MAN, board.at_coordinates(2, 2)
    assert_nil @session.selected
    assert_equal 1, @session.game.plies
  end

  # Java: opponentWithPiecesButNoLegalMoveAlsoLoses
  def test_opponent_with_pieces_but_no_legal_move_also_loses
    @session = session_for({ Square.at(2, 2) => "r", Square.at(0, 0) => "w" }, Side::RED)

    @session.click(2, 2)
    @session.click(1, 3)

    assert_equal 1, board.count(Side::WHITE)
    assert_empty Rules.legal_moves(@session.game.position)
    assert_equal Side::RED, @session.winner
    assert_equal :no_moves, @session.game.reason
  end

  # Java: resetFullyRestoresEvenAfterACompletedGame
  def test_reset_fully_restores_even_after_a_completed_game
    finished = ClickSession.new(Game.new(Position.build({ Square.at(0, 0) => "r",
                                                          Square.at(1, 1) => "w" }, Side::RED)))
    finished.click(0, 0)
    finished.click(2, 2)
    assert_equal Side::RED, finished.winner

    fresh = ClickSession.new

    assert_equal 12, fresh.board.count(Side::RED)
    assert_equal 12, fresh.board.count(Side::WHITE)
    assert_equal Side::RED, fresh.turn
    assert_nil fresh.selected
    assert_nil fresh.forced_jump
    assert_nil fresh.winner
    assert_empty fresh.destinations
    assert_equal Position.start, fresh.game.position
  end

  private

  def board
    @session.board
  end

  def session_for(pieces, side)
    ClickSession.new(Game.new(Position.build(pieces, side)))
  end
end
