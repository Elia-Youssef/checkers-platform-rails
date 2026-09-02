class MatchesController < ApplicationController
  include MatchScoped

  skip_before_action :set_match, only: :create

  # The match page. Anyone may open it: a player sees the controls for the seats they hold,
  # everybody else sees the same board read-only with a note (rubric 54).
  #
  # ?selected=11 is the whole selection mechanism with JavaScript off: the server renders that
  # piece's legal targets, computed by the engine, as forms that post one leg.
  def show
    @game = @match.game
    @selected = selected_square
  end

  # Start a game. Only hot-seat exists in this build step; the computer and online modes get
  # their own create paths in the phases that add them, and this refuses to invent a match for
  # a mode that cannot be played yet.
  def create
    unless params[:mode] == "hotseat"
      redirect_to root_path, status: :see_other,
        alert: "That way to play is not available yet." and return
    end

    match = Match.open_hotseat(user: Current.user, guest_key: Current.guest_key)
    redirect_to match_path(match), status: :see_other
  end
end
