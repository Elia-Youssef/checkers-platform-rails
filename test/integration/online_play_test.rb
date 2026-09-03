require "test_helper"

# The HTTP contract of online play: creating, the invite link, joining, the seat rule, draw
# offers, resignation off turn, cancelling and the rematch.
#
# Every case here runs through the real endpoints with one cookie jar per person, which is
# what an online match is: two browsers that never share a session. The rules are the
# server's, so a browser is never trusted with any of them.
#
#   403 :forbidden               any action from a session holding no seat (rubric 12)
#   422 :unprocessable_content   a rule refusal from somebody who does hold a seat
#
# Rack 3.2.7 has no :unprocessable_entity symbol, so the number 422 is asserted directly.
class OnlinePlayTest < ActionDispatch::IntegrationTest
  # ---- people, matches and moves -------------------------------------------------------

  # A browser with this user signed in through the real form.
  def sign_in(user)
    browser = open_session
    browser.post session_path, params: { email_address: user.email_address, password: "password" }
    browser.assert_response :redirect
    browser
  end

  # A browser with no account, which still gets a guest cookie the way a visitor does.
  def guest
    browser = open_session
    browser.get root_path
    browser
  end

  # Creates an online match from the home page form and returns it.
  def create_online(browser, colour: "red")
    browser.post matches_path, params: { mode: "online", colour: colour }
    browser.assert_response :redirect
    Match.order(:id).last
  end

  # A waiting match created by Ada, joined by Grace: the state everything else starts from.
  def active_match(colour: "red")
    ada = sign_in(users(:one))
    grace = sign_in(users(:two))
    match = create_online(ada, colour: colour)
    grace.get join_path(match.invite_token)
    grace.assert_response :redirect
    [ match.reload, ada, grace ]
  end

  def leg(browser, match, from, to)
    browser.post match_moves_path(match), params: { from: from, to: to }
  end

  # Plays whole PDN moves through one browser, asserting each leg was accepted.
  def play(browser, match, *texts)
    texts.each do |text|
      text.split(/[-x]/).map(&:to_i).each_cons(2) do |from, to|
        leg(browser, match, from, to)
        browser.assert_response :redirect, "leg #{from} to #{to} of #{text} was refused"
      end
    end
    match.reload
  end

  # ---- creating (rubric 19, 42) --------------------------------------------------------

  test "the home page offers the online create form to a signed-in visitor only" do
    get root_path
    assert_response :success
    assert_select "#mode-online form[action=?]", matches_path, 0
    assert_select "#mode-online a[href=?]", new_session_path

    ada = sign_in(users(:one))
    ada.get root_path
    ada.assert_response :success
    assert_select ada.html_document.root, "#mode-online form[action='#{matches_path}']" do
      assert_select "input[name=?][value=?]", "mode", "online"
      assert_select "input[name=?][value=?]", "colour", "red"
      assert_select "input[name=?][value=?]", "colour", "white"
      assert_select "input[name=?][value=?]", "colour", "random"
    end
  end

  test "the home page offers the join field to everyone" do
    get root_path

    assert_response :success
    assert_select "#mode-join form[action=?][method=?]", joins_path, "post" do
      assert_select "input[name=?]", "invite"
    end
  end

  test "creating an online match while signed out creates nothing and asks for sign in" do
    browser = guest

    assert_no_difference -> { Match.count } do
      browser.post matches_path, params: { mode: "online", colour: "red" }
    end
    browser.assert_redirected_to new_session_path

    # And signing in comes back to the page that holds the form.
    browser.post session_path, params: { email_address: users(:one).email_address, password: "password" }
    browser.assert_redirected_to root_url
  end

  test "creating an online match seats the creator in the colour they chose and waits" do
    ada = sign_in(users(:one))

    match = create_online(ada, colour: "white")

    assert_equal "online", match.mode
    assert_equal "waiting", match.status
    assert_equal users(:one), match.white_user
    assert_nil match.red_user
    assert_equal "red", match.free_seat
    assert_equal Draughts::Position::START_BOARD, match.position
    assert_equal "red", match.side_to_move
    assert_nil match.invite_token_used_at
    assert match.invite_open?
  end

  test "the invite token is at least 20 URL-safe characters and unguessable" do
    ada = sign_in(users(:one))

    tokens = 5.times.map { create_online(ada).invite_token }

    tokens.each do |token|
      assert_operator token.length, :>=, 20, "the invite token must be 20 characters or more"
      assert_match(/\A[A-Za-z0-9_-]+\z/, token, "the invite token must be URL-safe")
    end
    assert_equal 5, tokens.uniq.length, "two matches were given the same token"
  end

  test "a random colour is one of the two colours" do
    ada = sign_in(users(:one))

    colours = 8.times.map { create_online(ada, colour: "random").seats_held_by(user: users(:one)).first }

    assert_equal [], colours - Match::SIDES
    assert_equal 8, colours.length
  end

  test "a colour that is not a colour creates nothing" do
    ada = sign_in(users(:one))

    assert_no_difference -> { Match.count } do
      ada.post matches_path, params: { mode: "online", colour: "green" }
    end
    ada.assert_redirected_to root_path
  end

  # ---- the waiting page (rubric 38) ----------------------------------------------------

  test "the creator sees the invite link, a copy button and cancel, and nobody else does" do
    ada = sign_in(users(:one))
    match = create_online(ada)

    ada.get match_path(match)

    ada.assert_response :success
    assert_select ada.html_document.root, "##{Match::INVITE_ID} input[value=?]", join_url(match.invite_token)
    assert_select ada.html_document.root, "##{Match::INVITE_ID} a[href=?]", join_url(match.invite_token)
    assert_select ada.html_document.root, "##{Match::INVITE_ID} button[data-action=?]", "clipboard#copy"
    assert_select ada.html_document.root, "form[action=?]", match_cancellation_path(match)
    assert_select ada.html_document.root, ".status__headline", text: /Waiting for a second player/

    onlooker = sign_in(users(:two))
    onlooker.get match_path(match)

    onlooker.assert_response :success
    assert_select onlooker.html_document.root, "##{Match::INVITE_ID} input", 0
    assert_select onlooker.html_document.root, "form[action=?]", match_cancellation_path(match), 0
    assert_not_includes onlooker.response.body, match.invite_token,
      "the invite token leaked to somebody who is not the creator"
  end

  test "cancelling a waiting match closes it and kills the link" do
    ada = sign_in(users(:one))
    match = create_online(ada)

    ada.post match_cancellation_path(match)

    ada.assert_redirected_to root_path
    match.reload
    assert_equal "cancelled", match.status
    assert_not_nil match.invite_token_used_at
    assert_not match.invite_open?

    grace = sign_in(users(:two))
    grace.get join_path(match.invite_token)
    grace.assert_response :redirect
    assert_equal "cancelled", match.reload.status
    assert_nil match.white_user
  end

  # The players panel of a match nobody has joined. The open seat has no piece count (the men
  # are on the board, but "Open seat, 12 pieces" reads as though somebody were playing them),
  # and the sentence has to match the state: a cancelled match is not waiting for anybody.
  test "the open seat says what it is waiting for, and a cancelled match says nobody joined" do
    ada = sign_in(users(:one))
    match = create_online(ada, colour: "red")

    ada.get match_path(match)
    assert_select ada.html_document.root, ".player__count--empty", text: "waiting to join"
    assert_select ada.html_document.root, ".player__count", text: /piece/, count: 1

    ada.post match_cancellation_path(match)
    ada.get match_path(match)
    assert_select ada.html_document.root, ".player__count--empty", text: "nobody joined"
    assert_select ada.html_document.root, ".player__count--empty", text: "waiting to join", count: 0
    assert_select ada.html_document.root, ".player__count", text: /piece/, count: 1
  end

  test "a match that has been joined can no longer be cancelled" do
    match, ada, = active_match

    ada.post match_cancellation_path(match)

    assert_equal 422, ada.response.status
    assert_equal "active", match.reload.status
  end

  # ---- joining (rubric 19, 38) ---------------------------------------------------------

  test "the second player takes the free seat and the match goes active" do
    ada = sign_in(users(:one))
    grace = sign_in(users(:two))
    match = create_online(ada, colour: "red")

    grace.get join_path(match.invite_token)

    grace.assert_redirected_to match_path(match)
    match.reload
    assert_equal "active", match.status
    assert_equal users(:one), match.red_user
    assert_equal users(:two), match.white_user
    assert_not_nil match.invite_token_used_at
    assert_not match.invite_open?
    assert_equal [ "white" ], match.seats_held_by(user: users(:two))
  end

  test "a signed-out visitor opening the link signs in and lands in the match" do
    ada = sign_in(users(:one))
    match = create_online(ada)
    visitor = guest

    visitor.get join_path(match.invite_token)

    visitor.assert_redirected_to new_session_path
    assert_equal "waiting", match.reload.status

    visitor.post session_path, params: { email_address: users(:two).email_address, password: "password" }
    visitor.assert_redirected_to join_url(match.invite_token)
    visitor.follow_redirect!
    visitor.assert_redirected_to match_path(match)
    assert_equal "active", match.reload.status
    assert_equal users(:two), match.white_user
  end

  test "the creator cannot join their own match" do
    ada = sign_in(users(:one))
    match = create_online(ada)

    ada.get join_path(match.invite_token)

    ada.assert_redirected_to match_path(match)
    match.reload
    assert_equal "waiting", match.status
    assert_nil match.white_user
    assert match.invite_open?, "the creator's refused join spent the link"
  end

  test "a used link joins nothing a second time" do
    match, _ada, grace = active_match
    third = sign_in(users(:three))

    third.get join_path(match.invite_token)

    third.assert_response :redirect
    match.reload
    assert_equal users(:two), match.white_user
    assert_equal [], match.seats_held_by(user: users(:three))

    # And the player who did join reads it as "you are already playing here".
    grace.get join_path(match.invite_token)
    grace.assert_redirected_to match_path(match)
    assert_equal users(:two), match.reload.white_user
  end

  # The three closed doors, over HTTP, one per status. The audit's C1 went through the middle
  # one: the model answered "no refusal" for an active match, so only a controller check outside
  # the transaction stood between a forwarded link and a seated player being replaced.
  test "the link of an active match seats nobody and evicts nobody" do
    match, _ada, _grace = active_match
    before = match.attributes
    third = sign_in(users(:three))

    third.get join_path(match.invite_token)

    third.assert_response :redirect
    third.follow_redirect!
    assert_select third.html_document.root, ".flash--alert", text: /no longer open/
    assert_no_match(/You joined/, third.response.body)
    assert_select third.html_document.root, ".controls__note", text: /You are viewing this match/
    assert_equal before, match.reload.attributes, "opening a spent link changed the match"
    assert_equal users(:one), match.red_user
    assert_equal users(:two), match.white_user
  end

  test "the link of a finished match seats nobody" do
    match, ada, = active_match
    ada.post match_resignation_path(match)
    before = match.reload.attributes
    third = sign_in(users(:three))

    third.get join_path(match.invite_token)

    third.follow_redirect!
    assert_select third.html_document.root, ".flash--alert", text: /already finished/
    assert_equal before, match.reload.attributes
  end

  test "the link of a cancelled match seats nobody" do
    ada = sign_in(users(:one))
    match = create_online(ada)
    ada.post match_cancellation_path(match)
    before = match.reload.attributes
    third = sign_in(users(:three))

    third.get join_path(match.invite_token)

    third.follow_redirect!
    assert_select third.html_document.root, ".flash--alert", text: /cancelled/
    assert_equal before, match.reload.attributes
    assert_equal "cancelled", match.status
  end

  test "the join endpoint is rate limited per client" do
    ada = sign_in(users(:one))

    JoinsController::JOIN_ATTEMPTS.times do
      ada.get join_path("z" * 32)
      ada.assert_response :redirect
    end
    ada.get join_path("z" * 32)

    assert_equal 303, ada.response.status
    ada.follow_redirect!
    assert_select ada.html_document.root, ".flash--alert", text: /Too many attempts/
  end

  # The address key is one the client chooses: this application reads X-Forwarded-For, so a
  # sweep that varies the header gets a fresh counter every request (the session-6 diff review
  # measured 130 of 130 accepted that way). The second key is the identity behind the request,
  # which cannot be varied without signing in as somebody else.
  test "the join endpoint is rate limited per identity, whatever the forwarded address says" do
    ada = sign_in(users(:one))
    sweep = ->(index) { ada.get join_path("z" * 32),
                                headers: { "HTTP_X_FORWARDED_FOR" => "203.0.113.#{index % 250}" } }

    JoinsController::JOIN_ATTEMPTS.times { |index| sweep.call(index) }
    sweep.call(999)

    ada.follow_redirect!
    assert_select ada.html_document.root, ".flash--alert", text: /Too many attempts/,
      message: "a header sweep from one signed-in account was never refused"
  end

  test "a token that names no match joins nothing" do
    stranger = sign_in(users(:two))

    stranger.get join_path("a" * 32)

    stranger.assert_redirected_to root_path
  end

  test "the join field takes a whole invite link or the bare code" do
    ada = sign_in(users(:one))
    match = create_online(ada)
    grace = sign_in(users(:two))

    grace.post joins_path, params: { invite: join_url(match.invite_token) }
    grace.assert_redirected_to join_path(match.invite_token)

    grace.post joins_path, params: { invite: "  #{match.invite_token}  " }
    grace.assert_redirected_to join_path(match.invite_token)

    grace.post joins_path, params: { invite: "#{join_url(match.invite_token)}?utm=1" }
    grace.assert_redirected_to join_path(match.invite_token)

    grace.post joins_path, params: { invite: "not a link" }
    grace.assert_redirected_to new_join_path
  end

  # ---- the seat rule (rubric 12) -------------------------------------------------------

  test "a third user and a guest see the board read-only and every action they forge is 403" do
    match, = active_match
    before = match.attributes

    [ sign_in(users(:three)), guest ].each do |onlooker|
      onlooker.get match_path(match)
      assert_equal 200, onlooker.response.status
      assert_select onlooker.html_document.root, ".controls__note", text: /You are viewing this match/
      assert_select onlooker.html_document.root, "button.square:not([disabled])", 0
      assert_select onlooker.html_document.root, "form[action=?]", match_moves_path(match), 0
      assert_select onlooker.html_document.root, "a[href=?]", new_match_resignation_path(match), 0
      assert_select onlooker.html_document.root, "##{Match::MOVES_ID}"

      onlooker.post match_moves_path(match), params: { from: 11, to: 15 }
      assert_equal 403, onlooker.response.status, "a move from a session with no seat"
      assert_predicate onlooker.response.body, :empty?

      onlooker.post match_undo_path(match)
      assert_equal 403, onlooker.response.status, "an undo from a session with no seat"

      onlooker.get new_match_resignation_path(match)
      assert_equal 403, onlooker.response.status, "the resignation page for a session with no seat"

      onlooker.post match_resignation_path(match)
      assert_equal 403, onlooker.response.status, "a resignation from a session with no seat"

      onlooker.post match_draw_offer_path(match)
      assert_equal 403, onlooker.response.status, "a draw offer from a session with no seat"

      onlooker.post match_draw_accept_path(match)
      assert_equal 403, onlooker.response.status, "a draw acceptance from a session with no seat"

      onlooker.post match_draw_decline_path(match)
      assert_equal 403, onlooker.response.status, "a draw refusal from a session with no seat"

      onlooker.post match_cancellation_path(match)
      assert_equal 403, onlooker.response.status, "a cancellation from a session with no seat"

      onlooker.post match_rematch_path(match)
      assert_equal 403, onlooker.response.status, "a rematch from a session with no seat"
    end

    assert_equal before, match.reload.attributes
  end

  test "a player may not move on the other player's turn" do
    match, ada, grace = active_match

    grace.post match_moves_path(match), params: { from: 22, to: 18 }

    assert_equal 403, grace.response.status, "White moved while Red was to move"
    assert_equal 0, match.reload.moves.count

    play(ada, match, "11-15")
    ada.post match_moves_path(match), params: { from: 15, to: 18 }
    assert_equal 403, ada.response.status, "Red moved twice"
    assert_equal 1, match.reload.moves.count
  end

  test "undo is not available online, on the page or at the endpoint" do
    match, ada, = active_match
    play(ada, match, "11-15")

    ada.get match_path(match)
    assert_select ada.html_document.root, "form[action=?]", match_undo_path(match), 0

    ada.post match_undo_path(match)

    assert_equal 422, ada.response.status
    assert_select ada.html_document.root, ".flash--alert", text: /not available in an online match/
    assert_equal 1, match.reload.moves.count
  end

  test "each player sees only their own board as playable" do
    match, ada, grace = active_match

    ada.get match_path(match)
    # Four Red men can move from the opening position (squares 9 to 12), between them the
    # seven legal opening moves.
    assert_select ada.html_document.root, "button[data-legal-targets]", 4
    assert_select ada.html_document.root, "button[data-square='11'][data-legal-targets=?]", "15 16"
    assert_select ada.html_document.root, ".controls__turn", text: /Your move/

    grace.get match_path(match)
    assert_select grace.html_document.root, "button[data-legal-targets]", 0
    assert_select grace.html_document.root, "button.square:not([disabled])", 0
    assert_select grace.html_document.root, ".controls__turn", text: /Waiting for Ada to move/
  end

  # One rule for a match that is not running: a seat holder is refused with 422 and the sentence
  # that names the state, whichever colour they hold and whichever colour happened to be to move
  # when it stopped, and a session holding no seat is 403 as before. The colour matters because
  # side_to_move is frozen at the end: before this, the seat that was to move got 422 and the
  # other seat got 403 for the same act (session-7 audit, finding L3).
  test "on a finished match either seat holder is 422 with the state named, a stranger is 403" do
    match, ada, grace = active_match
    play(ada, match, "11-15")
    grace.post match_resignation_path(match)
    grace.assert_response :redirect
    match.reload
    assert_equal "finished", match.status
    assert_equal "white", match.side_to_move,
      "the point of this test is that the colour to move at the end is not the one asking"
    before = match.attributes

    { "Red" => ada, "White" => grace }.each do |colour, browser|
      refusals = {
        "a move" => -> { browser.post match_moves_path(match), params: { from: 11, to: 15 } },
        "an undo" => -> { browser.post match_undo_path(match) },
        "the resignation page" => -> { browser.get new_match_resignation_path(match) },
        "a resignation" => -> { browser.post match_resignation_path(match) },
        "a draw offer" => -> { browser.post match_draw_offer_path(match) },
        "a draw acceptance" => -> { browser.post match_draw_accept_path(match) },
        "a draw refusal" => -> { browser.post match_draw_decline_path(match) }
      }

      refusals.each do |what, act|
        act.call
        assert_equal 422, browser.response.status, "#{what} by #{colour} on a finished match"
        assert_select browser.html_document.root, ".flash--alert", text: /already finished/
      end
    end

    stranger = sign_in(users(:three))
    stranger.post match_moves_path(match), params: { from: 11, to: 15 }
    assert_equal 403, stranger.response.status, "no seat is still 403, not 422"
    assert_predicate stranger.response.body, :empty?

    assert_equal before, match.reload.attributes
  end

  test "on a cancelled match the seat holder is 422 and the sentence says it was cancelled" do
    ada = sign_in(users(:one))
    match = create_online(ada)
    ada.post match_cancellation_path(match)
    ada.assert_response :redirect
    before = match.reload.attributes

    ada.post match_moves_path(match), params: { from: 11, to: 15 }

    assert_equal 422, ada.response.status
    assert_select ada.html_document.root, ".flash--alert", text: /was cancelled/
    assert_equal before, match.reload.attributes
  end

  # ---- draw offers (rubric 25) ---------------------------------------------------------

  test "a draw offer lifecycle: offer, refuse a second, decline, clear on a move, accept" do
    match, ada, grace = active_match

    ada.post match_draw_offer_path(match)
    ada.assert_response :redirect
    assert_equal "red", match.reload.draw_offered_by

    # One pending offer at a time, from either side.
    ada.post match_draw_offer_path(match)
    assert_equal 422, ada.response.status
    grace.post match_draw_offer_path(match)
    assert_equal 422, grace.response.status
    assert_equal "red", match.reload.draw_offered_by

    # And the offering side cannot answer its own offer.
    ada.post match_draw_accept_path(match)
    assert_equal 422, ada.response.status
    assert_nil match.reload.result

    # The opponent sees it and declines.
    grace.get match_path(match)
    assert_select grace.html_document.root, "form[action=?]", match_draw_accept_path(match)
    assert_select grace.html_document.root, "form[action=?]", match_draw_decline_path(match)
    grace.post match_draw_decline_path(match)
    grace.assert_response :redirect
    assert_nil match.reload.draw_offered_by
    assert_equal "active", match.status

    # Offered again, and a completed move clears it.
    ada.post match_draw_offer_path(match)
    assert_equal "red", match.reload.draw_offered_by
    play(ada, match, "11-15")
    assert_nil match.reload.draw_offered_by, "a completed move did not clear the draw offer"

    # Offered a third time and accepted.
    grace.post match_draw_offer_path(match)
    assert_equal "white", match.reload.draw_offered_by
    ada.post match_draw_accept_path(match)
    ada.assert_response :redirect

    match.reload
    assert_equal "finished", match.status
    assert_equal "draw", match.result
    assert_equal "agreement", match.reason
    assert_nil match.draw_offered_by
    ada.get match_path(match)
    assert_select ada.html_document.root, ".status__headline", text: /Draw by agreement/
  end

  test "there is nothing to answer when no draw has been offered" do
    match, ada, grace = active_match

    grace.post match_draw_accept_path(match)
    assert_equal 422, grace.response.status
    ada.post match_draw_decline_path(match)
    assert_equal 422, ada.response.status
    assert_equal "active", match.reload.status
  end

  test "a draw cannot be offered once the match is over" do
    match, ada, grace = active_match
    grace.post match_resignation_path(match)
    grace.assert_response :redirect

    ada.post match_draw_offer_path(match)

    assert_equal 422, ada.response.status
    assert_equal "red_won", match.reload.result
  end

  test "a draw offer is refused in a hot-seat match" do
    get root_path
    post matches_path, params: { mode: "hotseat" }
    match = Match.order(:id).last

    post match_draw_offer_path(match)

    assert_response 422
    assert_nil match.reload.draw_offered_by
  end

  # ---- resignation off turn (rubric 26) ------------------------------------------------

  test "the player not on turn resigns their own colour and the other side wins" do
    match, ada, grace = active_match
    play(ada, match, "11-15")
    # White is to move now, so Red is the player not on turn.

    ada.get new_match_resignation_path(match)
    ada.assert_response :success
    assert_select ada.html_document.root, "#confirm-title", text: /Resign as Red/
    assert_equal "active", match.reload.status, "the confirmation page changed the match"

    ada.post match_resignation_path(match)

    ada.assert_response :redirect
    match.reload
    assert_equal "finished", match.status
    assert_equal "white_won", match.result
    assert_equal "resignation", match.reason
    grace.get match_path(match)
    assert_select grace.html_document.root, ".status__headline", text: /White wins by resignation/
  end

  # ---- the rematch (rubric 37) ---------------------------------------------------------

  test "play again creates a colour-swapped rematch and posts its link to the opponent" do
    match, ada, grace = active_match
    ada.post match_resignation_path(match)
    match.reload

    assert_difference -> { Match.count }, 1 do
      ada.post match_rematch_path(match)
    end
    rematch = Match.order(:id).last
    ada.assert_redirected_to match_path(rematch)

    assert_equal "online", rematch.mode
    assert_equal "waiting", rematch.status
    assert_equal [ "white" ], rematch.seats_held_by(user: users(:one)), "the colours were not swapped"
    assert_equal rematch, match.reload.rematch_match

    # The opponent finds the link in the match they are already looking at, and a viewer
    # does not: it carries the invite token.
    grace.get match_path(match)
    assert_select grace.html_document.root, "a[href=?]", join_path(rematch.invite_token)
    onlooker = sign_in(users(:three))
    onlooker.get match_path(match)
    assert_not_includes onlooker.response.body, rematch.invite_token,
      "the rematch token leaked to a viewer of the finished match"

    # One click and they are in.
    grace.get join_path(rematch.invite_token)
    grace.assert_redirected_to match_path(rematch)
    rematch.reload
    assert_equal "active", rematch.status
    assert_equal users(:two), rematch.red_user
    assert_equal users(:one), rematch.white_user
  end

  test "play again pressed by both players makes one rematch, not two" do
    match, ada, grace = active_match
    ada.post match_resignation_path(match)

    ada.post match_rematch_path(match)
    rematch = Match.order(:id).last

    assert_no_difference -> { Match.count } do
      grace.post match_rematch_path(match)
    end
    grace.assert_redirected_to match_path(rematch)
    rematch.reload
    assert_equal "active", rematch.status
    assert_equal users(:two), rematch.red_user
    assert_equal users(:one), rematch.white_user
  end

  # The diff review's regression R1: a rematch that has been cancelled is spent, so Play again
  # has to make a new one. Before this, the pointer was never replaced and both players were sent
  # to the cancelled row every time they pressed Play again, for good.
  test "play again after the rematch was cancelled makes a fresh one" do
    match, ada, grace = active_match
    ada.post match_resignation_path(match)
    ada.post match_rematch_path(match)
    first = Match.order(:id).last
    ada.post match_cancellation_path(first)
    assert_equal "cancelled", first.reload.status

    assert_difference -> { Match.count }, 1 do
      ada.post match_rematch_path(match)
    end
    second = Match.order(:id).last

    assert_not_equal first.id, second.id, "Play again returned the cancelled rematch"
    assert_equal "waiting", second.status
    assert_equal second, match.reload.rematch_match, "the finished match still points at the cancelled row"
    assert_equal [ "white" ], second.seats_held_by(user: users(:one))

    # And the opponent, pressing Play again after that, lands in the fresh one.
    assert_no_difference -> { Match.count } do
      grace.post match_rematch_path(match)
    end
    grace.assert_redirected_to match_path(second)
    assert_equal "active", second.reload.status
    assert_equal users(:two), second.red_user
  end

  test "play again after the rematch itself finished makes a fresh one" do
    match, ada, = active_match
    ada.post match_resignation_path(match)
    ada.post match_rematch_path(match)
    first = Match.order(:id).last
    first.join!(users(:two))
    first.resign!("red")

    assert_difference -> { Match.count }, 1 do
      ada.post match_rematch_path(match)
    end

    assert_equal Match.order(:id).last, match.reload.rematch_match
    assert_not_equal first.id, match.rematch_match_id
  end

  test "play again while the rematch is waiting or running still goes to it" do
    match, ada, grace = active_match
    ada.post match_resignation_path(match)
    ada.post match_rematch_path(match)
    waiting = Match.order(:id).last

    assert_no_difference -> { Match.count } do
      ada.post match_rematch_path(match)
    end
    ada.assert_redirected_to match_path(waiting)

    grace.get join_path(waiting.invite_token)
    assert_equal "active", waiting.reload.status
    assert_no_difference -> { Match.count } do
      ada.post match_rematch_path(match)
      grace.post match_rematch_path(match)
    end
    ada.assert_redirected_to match_path(waiting)
    grace.assert_redirected_to match_path(waiting)
  end

  test "a rematch is refused while the match is still running" do
    match, ada, = active_match

    assert_no_difference -> { Match.count } do
      ada.post match_rematch_path(match)
    end
    assert_equal 422, ada.response.status
  end

  # ---- persistence (rubric 14) ---------------------------------------------------------

  test "a waiting match, its token and its seats survive a reload in another browser" do
    ada = sign_in(users(:one))
    match = create_online(ada, colour: "white")
    token = match.invite_token

    reloaded = Match.find(match.id)

    assert_equal "waiting", reloaded.status
    assert_equal token, reloaded.invite_token
    assert_equal users(:one), reloaded.white_user
    assert_equal Draughts::Position::START_BOARD, reloaded.position
  end

  test "an online match plays on from what is stored, whichever browser asks" do
    match, ada, grace = active_match
    play(ada, match, "11-15")
    play(grace, match, "22-18")
    play(ada, match, "15x22")

    match.reload

    assert_equal 3, match.moves.count
    assert_equal %w[11-15 22-18 15x22], match.moves.map(&:pdn)
    assert_equal "white", match.side_to_move
    assert_equal 11, match.game.display_position.count(Draughts::Side::WHITE)
    ada.get match_path(match)
    assert_select ada.html_document.root, ".moves__move--latest", text: "15x22"
    grace.get match_path(match)
    assert_select grace.html_document.root, ".moves__move--latest", text: "15x22"
  end
end
