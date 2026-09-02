# One leg of a move: one click on the board.
#
# The request carries only two square numbers. Everything else is recomputed on the server
# from the stored position and the stored pending path by Draughts::Game, so a forged or a
# stale form can never make an illegal move happen. Who may post here at all is decided by
# MatchScoped's rule: the actor must hold the seat of the side to move (403 otherwise), and
# the engine decides everything after that (422).
class MovesController < ApplicationController
  include MatchScoped

  before_action :require_acting_seat

  def create
    @match.play_leg!(params[:from], params[:to])
    render_match
  rescue Draughts::Error => e
    refuse(e)
  end
end
