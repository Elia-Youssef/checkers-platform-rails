# Cancelling a waiting online match: the creator gives up on being joined.
#
# The row is kept and marked cancelled rather than deleted, so that the page can say what
# happened to anyone holding the address, and the invite token is marked spent at the same
# time, so the link joins nothing from then on.
#
# Only a seat holder may cancel (403 otherwise), and only while the match is still waiting: a
# match somebody has already joined is refused with 422, which is what stops a losing player
# cancelling a game in progress.
class CancellationsController < ApplicationController
  include MatchScoped

  before_action :require_seat

  def create
    @match.cancel!
    redirect_to root_path, status: :see_other, notice: "That match was cancelled and its invite link no longer works."
  rescue Draughts::Error => e
    refuse(e)
  end

  private
    def refusal_message(exception)
      "That match could not be cancelled: #{exception.message}."
    end
end
