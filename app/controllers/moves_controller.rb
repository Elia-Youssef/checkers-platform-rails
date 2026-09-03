# One leg of a move: one click on the board.
#
# The request carries only two square numbers. Everything else is recomputed on the server
# from the stored position and the stored pending path by Draughts::Game, so a forged or a
# stale form can never make an illegal move happen. Who may post here at all is decided by
# MatchScoped's rule: the actor must hold a seat here (403 otherwise) and it must be the seat
# of the side to move (403 again), a seat holder posting to a match that is not running is
# refused with 422 naming the state, and the engine decides everything after that (422).
#
# Against the computer the reply is played here, in this same request, before anything is
# rendered: the page the browser gets back, redirected or streamed, already carries the
# computer's answer and says that the human is to move again. There is no job and no polling.
# The human's leg is committed first, so between the two the row says it is the computer's
# turn and the seat rule refuses a second move from the human with 403 while the search runs.
class MovesController < ApplicationController
  include MatchScoped

  # The order is the rule: no seat here at all is 403, a seat on a match that is not running is
  # 422 naming the state, and a seat that is not the one to move is 403.
  before_action :require_seat
  before_action :require_active_match
  before_action :require_acting_seat

  def create
    leg = @match.play_leg!(params[:from], params[:to])
    # The computer answers a completed human move that did not end the match, here, before
    # anything is rendered. It answers nothing else: play_computer_reply! is a no-op unless
    # the row now says it is the computer's turn.
    @match.play_computer_reply! if leg.complete?
    render_match
  rescue Draughts::Error => e
    refuse(e)
  end
end
