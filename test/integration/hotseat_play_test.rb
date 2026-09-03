require "test_helper"

# The HTTP contract of hot-seat play: what each endpoint answers, and what it leaves behind.
#
#   422 :unprocessable_content   an illegal, out-of-turn or non-continuation leg, and an undo
#                                or a resignation the rules do not allow (rubric 4)
#   403 :forbidden               any mutating action from a session that holds no seat, which
#                                still sees the board read-only (rubric 12, 54)
#
# Rack 3.2.7 has no :unprocessable_entity symbol, so the number 422 is asserted directly.
class HotseatPlayTest < ActionDispatch::IntegrationTest
  START = "rrrrrrrrrrrr--------wwwwwwwwwwww".freeze

  # Creates a hot-seat match as this browser and returns it.
  def start_match
    get root_path
    post matches_path, params: { mode: "hotseat" }
    assert_response :redirect
    Match.order(:id).last
  end

  def leg(match, from, to, **options)
    post match_moves_path(match), params: { from: from, to: to }, **options
  end

  def play(match, *texts)
    texts.each do |text|
      text.split(/[-x]/).map(&:to_i).each_cons(2) do |from, to|
        leg(match, from, to)
        assert_response :redirect, "leg #{from} to #{to} of #{text} was refused"
      end
    end
    match.reload
  end

  # ---- creating -----------------------------------------------------------------------

  test "the home page offers a real form that creates a hot-seat match" do
    get root_path

    assert_response :success
    assert_select "#mode-hotseat form[action=?][method=?]", matches_path, "post" do
      assert_select "input[name=?][value=?]", "mode", "hotseat"
    end
  end

  test "creating a hot-seat match seats the browser in both colours and opens the board" do
    match = start_match

    assert_redirected_to match_path(match)
    assert_equal "hotseat", match.mode
    assert_equal "active", match.status
    assert_equal START, match.position
    assert_equal "red", match.side_to_move
    assert_equal %w[red white], match.seats_held_by(guest_key: signed_cookie(:guest_key))
  end

  test "a mode that does not exist creates nothing" do
    get root_path

    assert_no_difference -> { Match.count } do
      post matches_path, params: { mode: "sideways" }
    end
    assert_redirected_to root_path
  end

  # ---- the board page (rubric 7, 31, 44, 45) -------------------------------------------

  test "the board renders 32 dark squares as buttons with labels naming number and contents" do
    match = start_match
    get match_path(match)

    assert_response :success
    assert_select "button[data-square]", 32
    assert_select "button[aria-label=?]", "Square 11, Red man"
    assert_select "button[aria-label=?]", "Square 15, empty"
    assert_select "button[aria-label=?]", "Square 22, White man"
    assert_select "##{Match::BOARD_ID}"
    assert_select "##{Match::STATUS_ID}"
    assert_select "##{Match::MOVES_ID}"
    assert_select "##{Match::CONTROLS_ID}"
  end

  test "selecting a piece shows only that piece's engine-computed destinations" do
    match = start_match
    get match_path(match, selected: 11)

    assert_response :success
    assert_select "button.square--target", 2
    assert_select "button.square--target[aria-label=?]", "Square 15, empty, move here"
    assert_select "button.square--target[aria-label=?]", "Square 16, empty, move here"
    assert_select "button[data-square=?][aria-pressed=?]", "11", "true"
    assert_select "form[action=?] input[name=?][value=?]", match_moves_path(match), "from", "11"
  end

  test "a selection of a piece that cannot move offers nothing" do
    match = start_match
    play(match, "11-15", "22-18")

    get match_path(match, selected: 9)
    assert_response :success
    assert_select "button.square--target", 0
    assert_select "button[aria-pressed=true]", 0

    get match_path(match, selected: 15)
    assert_select "button.square--target", 1
    assert_select "button.square--target[aria-label=?]", "Square 22, empty, move here"
  end

  test "a selected square that is not a square number is ignored rather than an error" do
    match = start_match

    get match_path(match, selected: "banana")
    assert_response :success
    assert_select "button.square--target", 0

    get match_path(match, selected: 99)
    assert_response :success
    assert_select "button.square--target", 0
  end

  # ---- 422: the engine refuses (rubric 4) ----------------------------------------------

  test "a quiet move while a capture exists is 422 and leaves the match untouched" do
    match = start_match
    play(match, "11-15", "22-18")
    before = match.attributes

    leg(match, 9, 13)

    assert_response 422
    assert_equal before, match.reload.attributes
    assert_equal 2, match.moves.count
    assert_select "button[aria-label=?]", "Square 18, White man"
  end

  test "a move for the side not on turn is 422" do
    match = start_match
    before = match.attributes

    leg(match, 22, 18)

    assert_response 422
    assert_equal before, match.reload.attributes
    assert_equal 0, match.moves.count
  end

  test "a leg that does not continue a pending jump sequence is 422" do
    match = start_match
    play(match, "12-16", "24-20", "8-12", "28-24", "16-19")

    leg(match, 24, 15)
    assert_response :redirect
    match.reload
    assert_equal [ 24, 15 ], match.pending_path
    before = match.attributes

    leg(match, 23, 16)

    assert_response 422
    assert_equal before, match.reload.attributes
    assert_equal [ 24, 15 ], match.pending_path
    assert_equal 5, match.moves.count
  end

  test "a square number that is not on the board is 422" do
    match = start_match

    leg(match, 11, 99)
    assert_response 422

    leg(match, "", "")
    assert_response 422
    assert_equal 0, match.reload.moves.count
  end

  test "a move posted to a finished match is 422" do
    match = start_match
    post match_resignation_path(match)
    assert_response :redirect
    before = match.reload.attributes

    leg(match, 11, 15)

    assert_response 422
    assert_equal before, match.reload.attributes
  end

  # ---- the pending lock (rubric 8, 35) -------------------------------------------------

  test "while a jump sequence is pending only its continuations are offered and the controls go" do
    match = start_match
    play(match, "12-16", "24-20", "8-12", "28-24", "16-19")
    leg(match, 24, 15)

    get match_path(match)
    assert_response :success
    assert_select "button.square:not([disabled])", 1
    assert_select "button.square--target[aria-label=?]", "Square 8, empty, move here"
    assert_select "button[data-square=?]:not([disabled])", "8"
    assert_select "form[action=?]", match_undo_path(match), 0
    assert_select "a[href=?]", new_match_resignation_path(match), 0

    post match_undo_path(match)
    assert_response 422

    post match_resignation_path(match)
    assert_response 422

    match.reload
    assert_equal [ 24, 15 ], match.pending_path
    assert_equal "active", match.status
  end

  test "the last leg writes one move row for the whole sequence and unlocks the board" do
    match = start_match
    play(match, "12-16", "24-20", "8-12", "28-24", "16-19")
    leg(match, 24, 15)
    leg(match, 15, 8)

    assert_response :redirect
    match.reload
    assert_empty match.pending_path
    assert_equal 6, match.moves.count
    assert_equal "24x15x8", match.moves.last.pdn
    assert_equal "red", match.side_to_move

    get match_path(match)
    assert_select ".moves__move--latest", text: "24x15x8"
    assert_select "form[action=?]", match_undo_path(match), 1
  end

  # ---- 403: no seat (rubric 12, 54) ----------------------------------------------------

  test "a second guest sees the board read-only and every action it forges is 403" do
    match = start_match
    play(match, "11-15", "22-18")
    before = match.attributes

    open_session do |viewer|
      viewer.get match_path(match)
      assert_equal 200, viewer.response.status
      assert_select viewer.html_document.root, ".controls__note"
      assert_select viewer.html_document.root, "button.square:not([disabled])", 0
      assert_select viewer.html_document.root, ".moves__move", 2

      viewer.post match_moves_path(match), params: { from: 15, to: 22 }
      assert_equal 403, viewer.response.status

      viewer.post match_undo_path(match)
      assert_equal 403, viewer.response.status

      viewer.post match_resignation_path(match)
      assert_equal 403, viewer.response.status

      viewer.get new_match_resignation_path(match)
      assert_equal 403, viewer.response.status
    end

    assert_equal before, match.reload.attributes
  end

  test "a signed-in user who is not the creator is a viewer too" do
    match = start_match
    before = match.attributes

    open_session do |other|
      other.post session_path, params: { email_address: users(:one).email_address, password: "password" }
      other.get match_path(match)
      assert_equal 200, other.response.status
      assert_select other.html_document.root, ".controls__note"

      other.post match_moves_path(match), params: { from: 11, to: 15 }
      assert_equal 403, other.response.status
    end

    assert_equal before, match.reload.attributes
  end

  # ---- undo (rubric 35) ----------------------------------------------------------------

  test "undo takes back the last completed move" do
    match = start_match
    play(match, "11-15", "22-18")

    post match_undo_path(match)

    assert_redirected_to match_path(match)
    match.reload
    assert_equal 1, match.moves.count
    assert_equal "white", match.side_to_move
    assert_equal "11-15", match.moves.last.pdn
  end

  test "undo with nothing to undo is 422" do
    match = start_match

    post match_undo_path(match)

    assert_response 422
    assert_equal 0, match.reload.moves.count
  end

  test "undo is gone from the page and refused once the match has finished" do
    match = start_match
    play(match, "11-15")
    post match_resignation_path(match)

    get match_path(match)
    assert_select "form[action=?]", match_undo_path(match), 0

    post match_undo_path(match)
    assert_response 422
    assert_equal "finished", match.reload.status
  end

  # ---- resignation (rubric 26, 39) -----------------------------------------------------

  test "the resignation confirmation is a page of its own and cancelling changes nothing" do
    match = start_match
    play(match, "11-15", "22-18", "15x22")
    before = match.attributes

    get new_match_resignation_path(match)

    assert_response :success
    assert_select "[role=alertdialog]"
    assert_select "form[action=?]", match_resignation_path(match)
    assert_select "a[href=?]", match_path(match), text: "Cancel"
    assert_equal before, match.reload.attributes
  end

  test "resigning ends the match as a win for the other side and hides the controls" do
    match = start_match
    play(match, "11-15", "22-18")

    post match_resignation_path(match)

    assert_redirected_to match_path(match)
    match.reload
    assert_equal "finished", match.status
    assert_equal "white_won", match.result, "Red was to move, so White wins"
    assert_equal "resignation", match.reason

    get match_path(match)
    assert_select ".controls__result", text: /White wins by resignation/
    assert_select "form[action=?]", match_undo_path(match), 0
    assert_select "a[href=?]", new_match_resignation_path(match), 0
    assert_select "button.square:not([disabled])", 0
    assert_select "form[action=?] input[name=?][value=?]", matches_path, "mode", "hotseat"
  end

  test "play again starts a fresh match from the opening" do
    match = start_match
    play(match, "11-15")
    post match_resignation_path(match)

    assert_difference -> { Match.count }, 1 do
      post matches_path, params: { mode: "hotseat" }
    end

    fresh = Match.order(:id).last
    assert_redirected_to match_path(fresh)
    assert_equal START, fresh.position
    assert_equal "red", fresh.side_to_move
    assert_equal 0, fresh.moves.count
  end

  # ---- status, counts and the move list (rubric 32, 39, 54) ----------------------------

  test "the status line names both players, the turn, the counts and the move list" do
    match = start_match

    get match_path(match)
    assert_select ".status__headline", text: /Red to move/
    assert_select ".player__name", text: "Guest", count: 2
    assert_select ".player__count", text: "12 pieces", count: 2
    assert_select ".moves__empty"

    play(match, "11-15", "22-18", "15x22")
    get match_path(match)

    assert_select ".status__headline", text: /White to move/
    assert_select ".moves__pair", 2
    assert_select ".moves__move--latest", text: "15x22"
    assert_select ".player__count", text: "12 pieces", count: 1
    assert_select ".player__count", text: "11 pieces", count: 1
  end

  test "the last move's origin and destination are the only tinted squares" do
    match = start_match
    play(match, "11-15")

    get match_path(match)
    assert_select "button.square--last-move", 2
    assert_select "button.square--last-move[aria-label=?]", "Square 11, empty"
    assert_select "button.square--last-move[aria-label=?]", "Square 15, Red man"
  end

  test "a signed-in creator sees their display name in both seats" do
    post session_path, params: { email_address: users(:one).email_address, password: "password" }
    match = start_match

    get match_path(match)
    assert_select ".player__name", text: "Ada", count: 2
  end

  # ---- Turbo responses (the fragments phase 6 broadcasts) ------------------------------

  test "a Turbo request gets the four named fragments back" do
    match = start_match

    leg(match, 11, 15, headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" })

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    [ Match::BOARD_ID, Match::STATUS_ID, Match::MOVES_ID, Match::CONTROLS_ID, "flashes" ].each do |id|
      assert_match(/<turbo-stream action="replace" target="#{id}">/, response.body)
    end
  end

  test "a refused Turbo request is 422 and still carries the fragments and the message" do
    match = start_match
    play(match, "11-15", "22-18")

    leg(match, 9, 13, headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" })

    assert_response 422
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_match(/<turbo-stream action="replace" target="#{Match::BOARD_ID}">/, response.body)
    assert_match(/not legal here/, response.body)
    assert_equal 2, match.reload.moves.count
  end

  # ---- terminal positions reached through the endpoint (rubric 21) ---------------------

  test "capturing the last piece ends the match with no pieces left" do
    match = endgame({ "r" => [ 23 ], "w" => [ 27 ] }, side: "red")

    leg(match, 23, 32)

    assert_response :redirect
    match.reload
    assert_equal "finished", match.status
    assert_equal "red_won", match.result
    assert_equal "no_pieces", match.reason

    get match_path(match)
    assert_select ".status__headline--result", text: /Red wins, no pieces left/
    assert_select "button.square:not([disabled])", 0
  end

  test "boxing the side to move in ends the match with no legal move" do
    match = endgame({ "w" => [ 32 ], "r" => [ 28, 27, 19 ] }, side: "red")

    leg(match, 19, 23)

    assert_response :redirect
    match.reload
    assert_equal "finished", match.status
    assert_equal "red_won", match.result
    assert_equal "no_moves", match.reason

    get match_path(match)
    assert_select ".status__headline--result", text: /Red wins, White has no legal move/
  end

  # ---- persistence (rubric 14) ---------------------------------------------------------

  test "a new browser session sees the same board, moves and side to move" do
    match = start_match
    play(match, "11-15", "22-18", "15x22", "25x18")

    open_session do |other|
      other.get match_path(match)
      assert_equal 200, other.response.status
      assert_select other.html_document.root, ".moves__move", 4
      assert_select other.html_document.root, ".status__headline", text: /Red to move/
      assert_select other.html_document.root,
        "button[aria-label=?]", "Square 18, White man"
    end

    assert_equal match.position, Match.find(match.id).position
  end

  # ---- H1: the resignation confirmation names the actor's own seat ---------------------

  test "the hot-seat confirmation names the side to move, which is the seat the actor acts for" do
    match = start_match

    get new_match_resignation_path(match)
    assert_select ".confirm__title", text: /Resign as Red\?/
    assert_select "#confirm-body", text: /win for White/

    play(match, "11-15")
    get new_match_resignation_path(match)
    assert_select ".confirm__title", text: /Resign as White\?/
    assert_select "#confirm-body", text: /win for Red/

    post match_resignation_path(match)
    assert_equal "red_won", match.reload.result
  end

  test "a player holding one seat is told they resign their own colour, not the side to move" do
    match = online_match

    # Ada holds Red. After 11-15 it is White's turn, but Ada still resigns Red.
    sign_in_through_form(users(:one))
    leg(match, 11, 15)
    assert_response :redirect
    assert_equal "white", match.reload.side_to_move

    get new_match_resignation_path(match)
    assert_response :success
    assert_select ".confirm__title", text: /Resign as Red\?/
    assert_select "#confirm-body", text: /You hold the Red seat, and White is to move/
    assert_select "#confirm-body", text: /win for White/

    post match_resignation_path(match)
    assert_response :redirect
    match.reload
    assert_equal "white_won", match.result, "Ada resigned Red, so White must win"
    assert_equal "resignation", match.reason
  end

  test "the other seat holder resigning off turn is told the mirror image" do
    match = online_match

    sign_in_through_form(users(:two))
    assert_equal "red", match.side_to_move

    get new_match_resignation_path(match)
    assert_response :success
    assert_select ".confirm__title", text: /Resign as White\?/
    assert_select "#confirm-body", text: /You hold the White seat, and Red is to move/
    assert_select "#confirm-body", text: /win for Red/

    post match_resignation_path(match)
    match.reload
    assert_equal "red_won", match.result, "Grace resigned White, so Red must win"
  end

  # ---- H2: a match that is not active is not playable ----------------------------------

  test "a waiting match renders a static board, a waiting note and no controls" do
    match = waiting_match
    sign_in_through_form(users(:one))

    get match_path(match)

    assert_response :success
    assert_select ".status__headline", text: /Waiting for a second player/
    assert_select "button.square", 32
    assert_select "button.square:not([disabled])", 0, "a waiting match offered a live square"
    assert_select "button[data-legal-targets]", 0
    assert_select "form[action=?]", match_moves_path(match), 0
    assert_select ".controls__note", text: /waiting for a second player to take the White seat/
    assert_select "form[action=?]", match_undo_path(match), 0
    assert_select "a[href=?]", new_match_resignation_path(match), 0
    assert_select ".player--turn", 0
  end

  test "every action on a waiting match is 422 and says it has not started" do
    match = waiting_match
    sign_in_through_form(users(:one))
    before = match.attributes

    leg(match, 11, 15)
    assert_response 422
    assert_select ".flash--alert", text: /has not started yet/
    assert_select ".flash--alert", text: /finished/, count: 0

    post match_undo_path(match)
    assert_response 422
    assert_select ".flash--alert", text: /has not started yet/

    get new_match_resignation_path(match)
    assert_response 422
    assert_select ".flash--alert", text: /has not started yet/

    post match_resignation_path(match)
    assert_response 422
    assert_select ".flash--alert", text: /has not started yet/

    # The three draw endpoints answer the same way: a seat holder acting on a match that is
    # not running is 422 with the state named, never 403 (session-7 audit, finding L3).
    post match_draw_offer_path(match)
    assert_response 422
    assert_select ".flash--alert", text: /has not started yet/

    post match_draw_accept_path(match)
    assert_response 422
    assert_select ".flash--alert", text: /has not started yet/

    post match_draw_decline_path(match)
    assert_response 422
    assert_select ".flash--alert", text: /has not started yet/

    assert_equal before, match.reload.attributes
  end

  # ---- M3: the acting-seat rule ---------------------------------------------------------

  test "a move from an identity with no seat is 403" do
    match = online_match
    before = match.attributes

    open_session do |stranger|
      stranger.get root_path
      stranger.post match_moves_path(match), params: { from: 11, to: 15 }
      assert_equal 403, stranger.response.status
      assert_equal "", stranger.response.body
    end

    assert_equal before, match.reload.attributes
  end

  test "a move from the holder of the other seat only is 403, not 422" do
    match = online_match
    before = match.attributes

    # Grace holds White; Red is to move, so Grace does not hold the acting seat.
    sign_in_through_form(users(:two))
    leg(match, 11, 15)

    assert_response :forbidden
    assert_equal "", response.body
    assert_equal before, match.reload.attributes

    # Even for her own colour: she still does not hold the seat that is to move.
    leg(match, 22, 18)
    assert_response :forbidden
    assert_equal before, match.reload.attributes
  end

  test "the holder of the acting seat plays, and an illegal leg from that seat is 422" do
    match = online_match
    sign_in_through_form(users(:one))

    leg(match, 11, 15)
    assert_response :redirect
    assert_equal 1, match.reload.moves.count

    # Now White is to move, so Ada loses the acting seat: 403 again.
    leg(match, 15, 18)
    assert_response :forbidden

    sign_in_through_form(users(:two))
    leg(match, 22, 18)
    assert_response :redirect

    sign_in_through_form(users(:one))
    leg(match, 9, 13)
    assert_response 422, "the acting seat's illegal leg must be 422, not 403"
    assert_select ".flash--alert", text: /not legal here/
    assert_equal 2, match.reload.moves.count

    # A piece of the other colour, from the acting seat, is the engine's refusal too.
    leg(match, 23, 19)
    assert_response 422
    assert_equal 2, match.reload.moves.count
  end

  test "in hot-seat the actor holds both seats, so the acting seat is never a 403" do
    match = start_match

    leg(match, 22, 18)
    assert_response 422, "a hot-seat actor holds both seats: this is an out-of-turn 422"

    leg(match, 11, 15)
    assert_response :redirect
    leg(match, 11, 15)
    assert_response 422
  end

  # ---- L3: the confirmation page and the post refuse alike ------------------------------

  test "resignation new and create answer identically for the same refusal" do
    match = start_match
    play(match, "12-16", "24-20", "8-12", "28-24", "16-19")
    leg(match, 24, 15)

    get new_match_resignation_path(match)
    new_status = response.status
    new_carried_the_reason = response.body.include?("jump sequence is pending on square 15")

    post match_resignation_path(match)

    assert_equal 422, new_status
    assert_equal new_status, response.status
    assert new_carried_the_reason
    assert response.body.include?("jump sequence is pending on square 15")
    assert_equal "active", match.reload.status
  end

  test "a viewer gets 403 from both the confirmation page and the post" do
    match = start_match

    open_session do |stranger|
      stranger.get root_path
      stranger.get new_match_resignation_path(match)
      assert_equal 403, stranger.response.status
      stranger.post match_resignation_path(match)
      assert_equal 403, stranger.response.status
    end
  end

  private
    # Signs in through the real form, so the session cookie and Current.user are what a browser
    # would have.
    def sign_in_through_form(user)
      post session_path, params: { email_address: user.email_address, password: "password" }
      assert_response :redirect
    end

    # An active online match with Ada on Red and Grace on White. Phase 6 builds these for real;
    # phase 4 only has to behave correctly if one exists.
    def online_match
      Match.create!(mode: "online", status: "active", invite_token: Match.generate_invite_token,
                    invite_token_used_at: Time.current,
                    red_user: users(:one), white_user: users(:two))
    end

    # An online match with one seat filled, which is the state phase 6 creates and phase 4 must
    # not render as playable.
    def waiting_match
      Match.create!(mode: "online", status: "waiting", red_user: users(:one),
                    invite_token: SecureRandom.urlsafe_base64(24))
    end

    # A match seeded at a constructed position and seated to this browser's guest key, so the
    # endgames the terminal rules need can be reached in one real request.
    def endgame(pieces, side: "red")
      get root_path
      key = signed_cookie(:guest_key)
      board = Draughts::Position::EMPTY_BOARD.dup
      pieces.each { |char, squares| squares.each { |square| board[square - 1] = char } }

      Match.create!(mode: "hotseat", status: "active", red_guest_key: key, white_guest_key: key,
                    start_position: board, position: board, side_to_move: side)
    end
end
