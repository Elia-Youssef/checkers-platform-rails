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

  # Start a game. Hot-seat and versus the computer exist in this build step; online gets its
  # own path in the phase that adds it, and this refuses to invent a match for a mode that
  # cannot be played yet.
  #
  # Every parameter is checked before a row is created, and a parameter that is not one of the
  # pinned words sends the visitor back to the home page with the reason. Nothing here can
  # answer 500: the colour and the level are compared against Match::SIDES and
  # Match::AI_LEVELS, never passed through to the engine as they arrived.
  def create
    case params[:mode]
    when "hotseat" then create_hotseat
    when "ai" then create_ai
    else
      redirect_to root_path, status: :see_other, alert: "That way to play is not available yet."
    end
  end

  private
    def create_hotseat
      match = Match.open_hotseat(user: Current.user, guest_key: Current.guest_key)
      redirect_to match_path(match), status: :see_other
    end

    # A match against the computer. The human takes the colour they chose; when that is White
    # the computer plays Red's first move inside this request, so the board the browser is
    # redirected to already has a move on it and White is to move (RUBRIC.md items 13 and 33).
    def create_ai
      colour = params[:colour].to_s
      level = params[:level].to_s
      unless Match::SIDES.include?(colour)
        redirect_to root_path, status: :see_other,
          alert: "Choose Red or White to play the computer." and return
      end
      # Match::AI_LEVELS, not Draughts::AI.level?, which strips and downcases: the two checks
      # here should refuse the same way, and "one of the pinned words" is what the brief says.
      unless Match::AI_LEVELS.include?(level)
        redirect_to root_path, status: :see_other,
          alert: "Choose Easy, Medium or Hard to play the computer." and return
      end

      match = Match.open_ai(side: colour, level: level,
                           user: Current.user, guest_key: Current.guest_key)
      match.play_computer_reply! if match.computer_to_move?
      redirect_to match_path(match), status: :see_other
    end
end
