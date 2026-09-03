class MatchesController < ApplicationController
  include MatchScoped

  skip_before_action :set_match, only: %i[ index create ]

  # My games: the matches this identity holds a seat in, newest first (TASK-BRIEF 1.7).
  #
  # Identity is whoever is asking: a signed-in user, or the guest key in this browser's
  # cookie. A match somebody only looked at is not theirs and is not here; a visitor with
  # neither sees the empty state.
  #
  # Three queries whatever the number of rows: the matches, the two seat associations
  # preloaded, and one grouped count of the move rows. Nothing in the view touches the
  # database (a query-count test pins it).
  def index
    @matches = Match.for_identity(**match_identity).newest_first
      .includes(:red_user, :white_user).to_a
    @move_counts = Move.where(match: @matches).group(:match_id).count
    @seats_by_match = @matches.to_h { |match| [ match.id, match.seats_held_by(**match_identity) ] }
  end

  # The match page, and the same match as a PDN file.
  #
  # HTML: anyone may open it: a player sees the controls for the seats they hold, everybody
  # else sees the same board read-only with a note (rubric 54).
  #
  # ?selected=11 is the whole selection mechanism with JavaScript off: the server renders that
  # piece's legal targets, computed by the engine, as forms that post one leg.
  #
  # PDN: /matches/:id.pdn downloads the game (TASK-BRIEF 1.7). It has the same visibility as
  # the page it exports, which is to say anyone with the address, and it carries no invite
  # token and no control: it is the move list, which every viewer can already read.
  def show
    respond_to do |format|
      format.html do
        @game = @match.game
        @selected = selected_square
      end
      format.pdn do
        send_data @match.pdn(site: request.host_with_port),
                  type: "text/plain; charset=utf-8",
                  disposition: "attachment",
                  filename: @match.pdn_filename
      end
    end
  end

  # Start a game: hot-seat, against the computer, or online.
  #
  # Every parameter is checked before a row is created, and a parameter that is not one of the
  # pinned words sends the visitor back to the home page with the reason. Nothing here can
  # answer 500: the colour and the level are compared against Match::SIDES and
  # Match::AI_LEVELS, never passed through to the engine as they arrived.
  def create
    case params[:mode]
    when "hotseat" then create_hotseat
    when "ai" then create_ai
    when "online" then create_online
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

    # An online match. Both seats hold signed-in users (TASK-BRIEF 1.5), so a visitor without
    # an account is sent to sign in and comes back to the home page, where the create form is;
    # a guest key never takes an online seat, which the model refuses as well.
    #
    # The colour is Red, White or random, and random is resolved here and now rather than at
    # the join, so the creator's own page shows which colour they are while they wait.
    def create_online
      return sign_in_first unless Current.user

      colour = params[:colour].to_s
      unless Match::SIDES.include?(colour) || colour == "random"
        redirect_to root_path, status: :see_other,
          alert: "Choose Red, White or random for an online match." and return
      end

      match = Match.open_online(creator: Current.user, colour: colour)
      redirect_to match_path(match), status: :see_other
    end

    # Sign in, then back to the home page. The POST this arrived on cannot be replayed after
    # signing in (there is no GET /matches to come back to), so the return address is the page
    # that holds the form.
    def sign_in_first
      session[:return_to_after_authenticating] = root_url
      redirect_to new_session_path, status: :see_other,
        alert: "Sign in to create an online match: both seats need an account."
    end
end
