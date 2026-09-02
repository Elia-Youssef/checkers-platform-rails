# Resigning, in two steps so that it works with JavaScript switched off.
#
# GET  /matches/:id/resignation/new   the confirmation, rendered by the server: the board as
#                                     it stands, the colour this player would resign, who
#                                     would win, and Resign or Cancel.
# POST /matches/:id/resignation       the resignation itself.
#
# Cancel is a plain link back to the match and changes nothing. There is no JavaScript
# shortcut, on purpose: one confirmation path means one path to test and one path to get
# wrong. Both actions ask Match#resignation_refusal, so the confirmation page and the post
# refuse the same states, with the same message, at the same status.
#
# The resigning seat is the actor's own seat, never "the side to move": in hot-seat the actor
# holds both seats so the two coincide, but a player with one seat resigns their own colour
# whether or not it is their turn, and the other colour wins.
class ResignationsController < ApplicationController
  include MatchScoped

  before_action :require_seat
  before_action :set_resigning_side

  def new
    refusal = @match.resignation_refusal
    return refuse(Draughts::IllegalMove.new(refusal)) if refusal

    @game = @match.game
    @selected = nil
  end

  def create
    @match.resign!(@resigning_side)
    back_to_match
  rescue Draughts::Error => e
    refuse(e)
  end

  private
    def set_resigning_side
      @resigning_side = @seats.include?(@match.side_to_move) ? @match.side_to_move : @seats.first
      @winning_side = Draughts::Side.opponent(Draughts::Side.cast(@resigning_side)).to_s
    end

    def refusal_message(exception)
      "That resignation was refused: #{exception.message}."
    end
end
