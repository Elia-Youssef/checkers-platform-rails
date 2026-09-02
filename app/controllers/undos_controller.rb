# Undo: take back the last completed move.
#
# Hot-seat only in this build step. The model refuses an undo while a jump sequence is
# pending, once the match has finished and in an online match, so a forged post cannot get
# past a hidden button.
class UndosController < ApplicationController
  include MatchScoped

  before_action :require_seat

  def create
    @match.undo_last_move!
    render_match
  rescue Draughts::Error => e
    refuse(e)
  end

  private
    def refusal_message(exception)
      "That cannot be undone: #{exception.message}."
    end
end
