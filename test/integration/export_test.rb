require "test_helper"

# PDN export: GET /matches/:id.pdn (TASK-BRIEF 1.7, rubric 27).
#
# The file is the game as PDN: seven headers in the pinned order, a blank line, the numbered
# move text and the result token last. The notation is the engine's, so what is checked here is
# the HTTP answer, the headers this application fills in and the result mapping.
class ExportTest < ActionDispatch::IntegrationTest
  HEADER_NAMES = %w[ Event Site Date Red White Result GameType ].freeze

  def play(match, *texts)
    texts.each do |text|
      text.split(/[-x]/).map(&:to_i).each_cons(2) { |from, to| match.play_leg!(from, to) }
    end
    match.reload
  end

  def online_match
    match = Match.open_online(creator: users(:one), colour: "red")
    match.join!(users(:two))
    match.reload
  end

  # The headers of the file as [name, value] pairs, in the order they were written.
  def headers_of(body)
    body.lines.take_while { |line| line.start_with?("[") }.map do |line|
      line.match(/\A\[(\w+) "(.*)"\]\n?\z/) { |match| [ match[1], match[2] ] }
    end
  end

  def move_text(body)
    body.split("\n\n", 2).last.to_s
  end

  # The last thing in the file, which is the result token. PDN wraps the move text and the
  # result together at 80 columns, so a short game ends "... 24x15x8 1-0" on one line and a
  # long one ends with the token on a line of its own; either way it is the last token.
  def result_token(body)
    body.split(/\s+/).last
  end

  # ---- the response ---------------------------------------------------------------------

  test "the export answers 200 as an attachment of plain text" do
    match = online_match
    play(match, "11-15")

    get match_path(match, format: :pdn)

    assert_response :success
    assert_equal "text/plain; charset=utf-8", response.headers["Content-Type"]
    assert response.headers["Content-Disposition"].start_with?(
      %(attachment; filename="checkers-#{match.id}.pdn")),
      "Content-Disposition was #{response.headers["Content-Disposition"].inspect}"
    # Rails writes the RFC 6266 pair, the plain filename and the encoded one. Pinned exactly as
    # measured so that a change in either half is noticed.
    assert_equal %(attachment; filename="checkers-#{match.id}.pdn"; ) +
      "filename*=UTF-8''checkers-#{match.id}.pdn",
      response.headers["Content-Disposition"]
  end

  test "the seven headers are there, in the pinned order, with GameType 21" do
    match = online_match
    match.update_columns(created_at: Time.utc(2026, 9, 2, 23, 30))

    get match_path(match, format: :pdn)

    headers = headers_of(response.body)
    assert_equal HEADER_NAMES, headers.map(&:first)
    values = headers.to_h
    assert_equal "Checkers on Rails, online game", values["Event"]
    assert_equal "www.example.com", values["Site"], "the host the file was downloaded from"
    assert_equal "2026.09.02", values["Date"]
    assert_equal "Ada", values["Red"]
    assert_equal "Grace", values["White"]
    assert_equal "21", values["GameType"]
  end

  test "the headers name the mode and the seats of every kind of match" do
    hotseat = Match.open_hotseat(guest_key: SecureRandom.urlsafe_base64(24))
    get match_path(hotseat, format: :pdn)
    values = headers_of(response.body).to_h
    assert_equal "Checkers on Rails, hot-seat game", values["Event"]
    assert_equal "Guest", values["Red"]
    assert_equal "Guest", values["White"]

    computer = Match.open_ai(side: "red", level: "hard", user: users(:one))
    get match_path(computer, format: :pdn)
    values = headers_of(response.body).to_h
    assert_equal "Checkers on Rails, versus the computer game", values["Event"]
    assert_equal "Ada", values["Red"]
    assert_equal "Computer (Hard)", values["White"]
  end

  test "a quote or a backslash in a display name is escaped as PDN requires" do
    users(:one).update!(display_name: 'Ada "Q" \\ B')
    match = online_match

    get match_path(match, format: :pdn)

    assert_includes response.body, %([Red "Ada \\"Q\\" \\\\ B"])
  end

  # ---- the move text and the result ------------------------------------------------------

  test "a Red win writes the moves as numbered pairs and ends with 1-0" do
    match = online_match
    play(match, "12-16", "24-20", "8-12", "28-24", "16-19", "24x15x8")
    match.resign!("white")

    get match_path(match, format: :pdn)

    body = response.body
    assert_equal "red_won", match.reload.result
    assert_includes move_text(body), "1. 12-16 24-20 2. 8-12 28-24 3. 16-19 24x15x8"
    assert_includes move_text(body), "24x15x8", "a whole jump sequence is one move, written with x"
    assert_equal "1-0", result_token(body)
    assert body.end_with?(" 1-0\n"), "the result token is last, followed by a newline"
    assert_equal "1-0", headers_of(body).to_h["Result"]
  end

  test "a White win ends with 0-1 and a draw with 1/2-1/2" do
    white_win = online_match
    white_win.resign!("red")
    get match_path(white_win, format: :pdn)
    assert_equal "white_won", white_win.reload.result
    assert_equal "0-1", result_token(response.body)
    assert_equal "0-1", headers_of(response.body).to_h["Result"]

    drawn = online_match
    drawn.offer_draw!("red")
    drawn.answer_draw!("white", accept: true)
    get match_path(drawn, format: :pdn)
    assert_equal "draw", drawn.reload.result
    assert_equal "1/2-1/2", result_token(response.body)
    assert_equal "1/2-1/2", headers_of(response.body).to_h["Result"]
  end

  test "a match that has not finished ends with a star" do
    active = online_match
    play(active, "11-15")
    get match_path(active, format: :pdn)
    assert_equal "*", result_token(response.body)
    assert_equal "*", headers_of(response.body).to_h["Result"]

    waiting = Match.open_online(creator: users(:one), colour: "red")
    get match_path(waiting, format: :pdn)
    assert_equal "*", result_token(response.body)
    assert_equal "*", move_text(response.body).chomp, "a match with no moves is the token alone"

    cancelled = Match.open_online(creator: users(:one), colour: "red")
    cancelled.cancel!
    get match_path(cancelled, format: :pdn)
    assert_equal "*", result_token(response.body)
  end

  test "the move text is wrapped at eighty columns" do
    match = online_match
    # A long game, played by always taking the engine's first legal move: legal by
    # construction, and long enough that the move text has to wrap several times.
    40.times do
      break if match.finished?

      play(match, match.game.legal_moves.first.pdn)
    end

    get match_path(match, format: :pdn)

    lines = move_text(response.body).lines.map(&:chomp)
    assert_operator lines.length, :>, 2, "the move text should have wrapped"
    assert(lines.all? { |line| line.length <= 80 }, "longest line was #{lines.map(&:length).max}")
    assert_equal 40, match.reload.moves.count
  end

  # ---- who may download it ---------------------------------------------------------------

  test "anyone who can see the match can export it, and an unknown match is 404" do
    match = online_match
    play(match, "11-15")

    get match_path(match, format: :pdn)
    assert_response :success, "a signed-out visitor"

    linus = open_session
    linus.post session_path, params: { email_address: users(:three).email_address, password: "password" }
    linus.get match_path(match, format: :pdn)
    linus.assert_response :success, "a signed-in visitor holding no seat"
    assert_not_includes linus.response.body, match.invite_token.to_s, "no invite token in the file"

    get "/matches/#{Match.maximum(:id).to_i + 1000}.pdn"
    assert_response :not_found
  end

  test "the finished match page and My games link to the export" do
    ada = open_session
    ada.post session_path, params: { email_address: users(:one).email_address, password: "password" }
    match = online_match
    match.resign!("white")

    ada.get match_path(match)
    ada.assert_select "a[href=?]", match_path(match, format: :pdn), text: "Export PDN"
    ada.assert_select "a[href=?]", match_replay_path(match), text: "Replay"

    ada.get matches_path
    ada.assert_select "tr#match-row-#{match.id} a[href=?]", match_path(match, format: :pdn)
  end

  test "a viewer of a finished match is offered the replay and the export and no control" do
    match = online_match
    match.resign!("white")

    get match_path(match)

    assert_select "a[href=?]", match_path(match, format: :pdn), text: "Export PDN"
    assert_select "a[href=?]", match_replay_path(match), text: "Replay"
    assert_select "form[action=?]", match_moves_path(match), count: 0
    assert_select "form[action=?]", match_rematch_path(match), count: 0
  end
end
