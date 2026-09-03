# Draw offers, the only ending two players have to agree on.
#
#   POST /matches/:id/draw/offer     offer a draw for the seat this session holds
#   POST /matches/:id/draw/accept    the opponent agrees: the match ends as a draw
#   POST /matches/:id/draw/decline   the opponent refuses: the offer is cleared, play goes on
#
# Three plain POSTs, so every step works with JavaScript switched off. Who may post is
# MatchScoped's rule: a session holding no seat is 403 before anything is read, and every
# rule refusal (not online, not active, an offer already pending, no offer to answer, or
# answering your own offer) is the model's and comes back as 422.
#
# One pending offer at a time, and any completed move clears it: Match#write_state_from sets
# draw_offered_by back to nil on every move, undo and resignation, so a move that lands while
# an offer is out cancels it without this controller knowing anything about moves.
class DrawOffersController < ApplicationController
  include MatchScoped

  before_action :require_seat
  before_action :require_active_match

  def create
    @match.offer_draw!(acting_seat)
    accepted("Draw offered. Waiting for #{@match.seat_name(opposing_seat)} to answer.")
  rescue Draughts::Error => e
    refuse(e)
  end

  def accept
    @match.answer_draw!(acting_seat, accept: true)
    accepted("Draw agreed.")
  rescue Draughts::Error => e
    refuse(e)
  end

  def decline
    @match.answer_draw!(acting_seat, accept: false)
    accepted("Draw offer declined.")
  rescue Draughts::Error => e
    refuse(e)
  end

  private
    # The seat this session acts for. Online that is the one seat it holds; the model refuses
    # a draw offer in any other mode, so a hot-seat player's forged post is a 422 and never
    # depends on which of their two seats this picked.
    def acting_seat
      @seats.first
    end

    def opposing_seat
      Draughts::Side.opponent(Draughts::Side.cast(acting_seat)).to_s
    end

    def accepted(message)
      render_match(notice: message)
    end

    def refusal_message(exception)
      "That draw offer was refused: #{exception.message}."
    end
end
