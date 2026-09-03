# Play again on a finished online match.
#
# It creates a new waiting match with the colours swapped, seats the player who asked, and
# records it on the finished match, which then broadcasts: the opponent's own controls
# fragment gains a link straight into the new game, so a rematch is one click for both of
# them and nobody has to copy an address.
#
# The link travels only on the opponent's seat stream, never on the viewer stream, because it
# carries an invite token: a viewer of the finished match must not be able to read it and take
# the seat the rematch is being offered to.
#
# Pressing Play again second does not make a third match: Match#start_rematch! sees the
# waiting rematch, takes its free seat, and both players land in the same game.
class RematchesController < ApplicationController
  include MatchScoped

  before_action :require_seat

  def create
    rematch = @match.start_rematch!(user: Current.user)
    redirect_to match_path(rematch), status: :see_other
  rescue Draughts::Error => e
    refuse(e)
  rescue ArgumentError
    # A guest holding a seat in a hot-seat match cannot start an online rematch; the model
    # says so with an ArgumentError because no signed-in user was passed.
    refuse(Draughts::IllegalMove.new("a rematch needs a signed-in player"))
  end

  private
    def refusal_message(exception)
      "That rematch was refused: #{exception.message}."
    end
end
