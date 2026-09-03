# Everything the four match controllers share: finding the match, deciding what the visitor
# may do to it, and rendering the answer.
#
# ---------------------------------------------------------------------------------------
# THE AUTHORIZATION RULE, in one place. Every match action obeys it and nothing else decides.
#
# A *seat* is Red or White in this match, held by a signed-in user or by a browser's guest
# key. The *acting seat* is the seat of the side to move. In a hot-seat match one identity
# holds both seats, so it always holds the acting seat.
#
#   Reading a match       anyone. An identity holding no seat sees the board, the move list
#                         and the status read-only, with a note and no controls (rubric 54).
#
#   A move (one leg)      the actor must hold the acting seat.
#                         no seat at all, or only the other seat  -> 403 Forbidden, nothing
#                         changes (TASK-BRIEF 1.6, "refuses actions from anyone who does not
#                         hold the acting seat with a 403", and section 2, "wrong seat ...
#                         HTTP 403"); this is what stops one online player moving on the
#                         other's turn or moving the other's pieces.
#                         holds a seat, match not active         -> 422 with the sentence
#                         naming the state, for either seat holder alike (see
#                         require_active_match).
#                         holds the acting seat, leg illegal     -> 422, decided by the
#                         engine alone: a quiet move while a capture exists, a leg that does
#                         not continue a pending jump, a piece of the other colour, a square
#                         that is not on the board (TASK-BRIEF section 2, "illegal or
#                         out-of-turn move: HTTP 422", and rubric 4, whose three probes are
#                         all posted in a hot-seat match where the actor holds both seats).
#
#   Resignation           any seat holder, at any time while the match is active, on turn or
#                         not: a player may resign whenever they like (TASK-BRIEF 1.1). No
#                         seat -> 403. A rule refusal (a jump pending, the match not active)
#                         -> 422, from both the confirmation page and the post, with the same
#                         message. The seat that resigns is the actor's own; in hot-seat the
#                         actor holds both, so it is the side to move.
#
#   Undo                  hot-seat and versus the computer only. No seat -> 403; online, a
#                         jump pending, nothing to undo, or the match over -> 422.
#
#   Draw offer,           online only, any seat holder. No seat -> 403. Not online, not
#   accept, decline       active, an offer already pending, no offer to answer, or answering
#                         your own offer -> 422. Only the seated opponent can answer, which
#                         is the model's rule (Match#draw_answer_refusal), not the page's.
#
#   Cancel                a seat holder of a waiting online match. No seat -> 403; a match
#                         somebody has already joined, or one that is over -> 422.
#
#   Rematch               a seat holder of a finished online match. No seat -> 403;
#                         everything else -> 422.
#
#   Join                  JoinsController, not this concern: it finds the match by its invite
#                         token instead of by id, requires a signed-in user, and refuses the
#                         creator and a spent link with a notice.
#
# 422 is written :unprocessable_content. Rack 3.2.7 removed the older :unprocessable_entity
# symbol. Every 403 answer has an empty body and every 422 answer leaves the row untouched.
# ---------------------------------------------------------------------------------------
module MatchScoped
  extend ActiveSupport::Concern

  UNPROCESSABLE = :unprocessable_content

  included do
    allow_unauthenticated_access
    before_action :set_match
    helper_method :match_identity
  end

  private
    def set_match
      @match = Match.find(params[:match_id] || params[:id])
      @seats = @match.seats_held_by(**match_identity)
      @viewer = @seats.empty?
      # Which live stream this page listens on, or nil when this browser is the only thing
      # that can change the match. See MatchBroadcasts.
      @audience = @match.live_audience(@seats)
    end

    # Who is asking: a signed-in user, or the browser's guest key. Both are set for every
    # request by the Authentication and GuestIdentity concerns.
    def match_identity
      { user: Current.user, guest_key: Current.guest_key }
    end

    # A mutating action needs a seat. A viewer gets 403 and the match is untouched, whatever
    # format asked and whatever the forged form contained.
    def require_seat
      head :forbidden if @seats.empty?
    end

    # A move needs the seat of the side to move. An identity that holds no seat, and an
    # identity that holds only the other seat, are both acting for a seat they do not hold, so
    # both are 403 and neither reaches the engine.
    def require_acting_seat
      head :forbidden unless @seats.include?(@match.side_to_move)
    end

    # A participant acting on a match that is not running gets 422 and the sentence that names
    # the state, whichever seat they hold and whichever colour was to move when it ended.
    #
    # It runs after require_seat and before require_acting_seat, which is what makes the code
    # mean one thing each: 403 is "this session holds no seat here, or not the seat it is
    # acting for", 422 is "the match cannot be acted on now". Before this, a move posted to a
    # finished match answered 403 or 422 depending on which colour happened to be to move when
    # it ended, because side_to_move is frozen at the end and require_acting_seat compares
    # against it: the same situation, two codes (session-7 audit, finding L3).
    #
    # Cancel and rematch do not use it and must not: cancelling is only ever done to a waiting
    # match and a rematch only to a finished one, so "not active" is their normal case and each
    # has its own refusal in the model.
    def require_active_match
      reason = @match.inactive_reason
      refuse(Draughts::IllegalMove.new(reason)) if reason
    end

    # The square the page should show as selected, or nil. It is a plain URL parameter, which
    # is what makes selection work with JavaScript switched off; the board partial ignores it
    # unless that square really has legal moves, so a hand-typed ?selected=9 offers nothing.
    def selected_square
      value = params[:selected].presence
      return nil if value.nil?

      Match.square_number(value)
    rescue Draughts::Error
      nil
    end

    # The answer to an accepted or refused action.
    #
    # Turbo request: the four named fragments, so the board, the move list, the status line
    # and the controls all update in place (phase 6 broadcasts the same four).
    # Plain request: a redirect back to the match page when the action was accepted, and a
    # re-render of the match page with the 422 when it was not, showing the position before
    # the attempt.
    def render_match(status: :ok, notice: nil)
      @game = @match.game
      @selected = nil

      # HTML is declared first on purpose. respond_to falls back to the first declared format
      # when the client sends Accept: */*, which is what curl and a scripted walkthrough send,
      # and the plain path is the one that must work for them. Turbo asks for
      # text/vnd.turbo-stream.html explicitly and still gets the streams.
      #
      # A notice is carried by the redirect for a plain client and put in the flash zone of
      # the stream response for a Turbo one, which is the same message either way.
      respond_to do |format|
        format.html do
          if status == :ok
            back_to_match(**(notice ? { notice: notice } : {}))
          else
            render template: "matches/show", status: status
          end
        end
        format.turbo_stream do
          flash.now[:notice] = notice if notice
          render template: "matches/update", status: status
        end
      end
    end

    # 303 See Other, so that a browser and Turbo both follow a redirect after a POST with a
    # GET of the match page.
    def back_to_match(**options)
      redirect_to match_path(@match), status: :see_other, **options
    end

    # Every refusal the engine raises becomes a 422 with the engine's own message.
    def refuse(exception)
      flash.now[:alert] = refusal_message(exception)
      render_match(status: UNPROCESSABLE)
    end

    def refusal_message(exception)
      case exception
      when Draughts::InvalidPosition then "That square is not on the board."
      else "That move is not legal here: #{exception.message}."
      end
    end
end
