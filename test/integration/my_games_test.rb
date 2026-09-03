require "test_helper"

# My games: /matches, the list of the matches the current identity holds a seat in
# (TASK-BRIEF 1.7, rubric 34 and 14).
class MyGamesTest < ActionDispatch::IntegrationTest
  def sign_in(user)
    browser = open_session
    browser.post session_path, params: { email_address: user.email_address, password: "password" }
    browser.assert_response :redirect
    browser
  end

  def guest_browser
    browser = open_session
    browser.get root_path
    browser
  end

  # An online match between Ada and Grace, active.
  def online_match
    match = Match.open_online(creator: users(:one), colour: "red")
    match.join!(users(:two))
    match.reload
  end

  def play(match, *texts)
    texts.each do |text|
      text.split(/[-x]/).map(&:to_i).each_cons(2) { |from, to| match.play_leg!(from, to) }
    end
    match.reload
  end

  # ---- who sees what -------------------------------------------------------------------

  test "a fresh visitor sees the empty state and no table" do
    get matches_path

    assert_response :success
    assert_select "h1", "My games"
    assert_select "table.games", count: 0
    assert_select "p.lede", /Nothing here yet/
  end

  test "a guest sees the matches started in this browser and nobody else's" do
    browser = guest_browser
    browser.post matches_path, params: { mode: "hotseat" }
    mine = Match.order(:id).last

    stranger = guest_browser
    stranger.post matches_path, params: { mode: "hotseat" }
    theirs = Match.order(:id).last

    browser.get matches_path
    browser.assert_response :success
    browser.assert_select "tr#match-row-#{mine.id}", count: 1
    browser.assert_select "tr#match-row-#{theirs.id}", count: 0
  end

  test "a signed-in user sees every match either of their seats holds" do
    ada = sign_in(users(:one))
    online = online_match
    ada.post matches_path, params: { mode: "hotseat" }
    hotseat = Match.order(:id).last

    ada.get matches_path
    ada.assert_response :success
    ada.assert_select "tr#match-row-#{online.id}", count: 1
    ada.assert_select "tr#match-row-#{hotseat.id}", count: 1
  end

  test "a match this identity only viewed is not listed" do
    match = online_match
    linus = sign_in(users(:three))

    linus.get match_path(match)
    linus.assert_response :success
    linus.assert_select ".controls__note", /You are viewing this match/

    linus.get matches_path
    linus.assert_select "tr#match-row-#{match.id}", count: 0
    linus.assert_select "table.games", count: 0
  end

  test "the list is newest first" do
    ada = sign_in(users(:one))
    older = Match.open_hotseat(user: users(:one))
    older.update_columns(created_at: 2.days.ago)
    middle = Match.open_hotseat(user: users(:one))
    middle.update_columns(created_at: 1.day.ago)
    newer = Match.open_hotseat(user: users(:one))

    ada.get matches_path
    ids = css_select_ids(ada.response.body)

    assert_equal [ newer.id, middle.id, older.id ], ids
  end

  # ---- what a row says -----------------------------------------------------------------

  test "a hot-seat row names the guest, the mode, the state and the move count" do
    browser = guest_browser
    browser.post matches_path, params: { mode: "hotseat" }
    match = Match.order(:id).last
    play(match, "11-15", "22-18")

    browser.get matches_path
    browser.assert_select "tr#match-row-#{match.id}" do
      browser.assert_select ".games__mode a", text: "Hot-seat"
      # One browser holds both seats, so there is no opponent to name.
      browser.assert_select ".games__opponent", text: "Yourself, both seats"
      browser.assert_select ".games__state", text: "In play, Red to move"
      browser.assert_select ".games__count", text: "2 moves"
    end
  end

  # A signed-in player's own hot-seat game used to name that player in the Opponent column,
  # which reads as playing against yourself (round-2 adoption audit, finding L5). Both seats
  # are the same identity, so the cell says that instead; the board itself still shows the
  # display name on both sides.
  test "a hot-seat row for a signed-in player says both seats are theirs" do
    ada = sign_in(users(:one))
    match = Match.open_hotseat(user: users(:one))

    ada.get matches_path
    ada.assert_select "tr#match-row-#{match.id} .games__opponent", text: "Yourself, both seats"
    ada.assert_select "tr#match-row-#{match.id} .games__opponent", text: "Ada", count: 0

    ada.get match_path(match)
    ada.assert_select ".player__name", text: "Ada", count: 2
  end

  test "a computer row names the computer and its level" do
    browser = guest_browser
    browser.post matches_path, params: { mode: "ai", colour: "red", level: "hard" }
    match = Match.order(:id).last

    browser.get matches_path
    browser.assert_select "tr#match-row-#{match.id}" do
      browser.assert_select ".games__mode a", text: "Computer"
      browser.assert_select ".games__opponent", text: "Computer (Hard)"
      browser.assert_select ".games__count", text: "0 moves"
    end
  end

  test "an online row names the opponent, and a waiting one names the open seat" do
    ada = sign_in(users(:one))
    waiting = Match.open_online(creator: users(:one), colour: "red")
    active = online_match
    play(active, "11-15")

    ada.get matches_path
    ada.assert_select "tr#match-row-#{waiting.id}" do
      ada.assert_select ".games__mode a", text: "Online"
      ada.assert_select ".games__opponent", text: "Open seat"
      ada.assert_select ".games__state", text: "Waiting for a second player"
    end
    ada.assert_select "tr#match-row-#{active.id}" do
      ada.assert_select ".games__opponent", text: "Grace"
      ada.assert_select ".games__state", text: "In play, White to move"
      ada.assert_select ".games__count", text: "1 move"
    end
  end

  test "a finished row states the result and its reason in words" do
    ada = sign_in(users(:one))
    resigned = online_match
    resigned.resign!("white")
    drawn = online_match
    drawn.offer_draw!("red")
    drawn.answer_draw!("white", accept: true)
    cancelled = Match.open_online(creator: users(:one), colour: "white")
    cancelled.cancel!

    ada.get matches_path
    ada.assert_select "tr#match-row-#{resigned.id} .games__state", text: "Red wins by resignation"
    ada.assert_select "tr#match-row-#{drawn.id} .games__state", text: "Draw by agreement"
    ada.assert_select "tr#match-row-#{cancelled.id} .games__state", text: "Cancelled"
  end

  # ---- the links -----------------------------------------------------------------------

  test "every row links to its match, and a finished row also to the replay and the export" do
    ada = sign_in(users(:one))
    active = online_match
    finished = online_match
    finished.resign!("red")

    ada.get matches_path
    ada.assert_select "tr#match-row-#{active.id}" do
      ada.assert_select "a[href=?]", match_path(active), count: 2 # the mode and Open
      ada.assert_select "a[href=?]", match_replay_path(active), count: 0
    end
    ada.assert_select "tr#match-row-#{finished.id}" do
      ada.assert_select "a[href=?]", match_path(finished), text: "Online"
      ada.assert_select "a[href=?]", match_replay_path(finished), text: "Replay"
      ada.assert_select "a[href=?]", match_path(finished, format: :pdn), text: "Export PDN"
    end
  end

  # A guest is a cookie in one browser and nothing else, so a cleared or expired cookie takes
  # these games off this page for good while leaving them in the database and at their addresses
  # (session-7 audit, finding L8). Say so where a guest can read it, and only to a guest.
  test "a guest with games is told they belong to this browser, with both ways out" do
    browser = guest_browser
    browser.post matches_path, params: { mode: "hotseat" }
    browser.get matches_path

    browser.assert_response :success
    assert_select browser.html_document.root, ".games__note", text: /belong to this browser/
    assert_select browser.html_document.root, ".games__note a[href=?]", new_registration_path
    assert_select browser.html_document.root, ".games__note a[href=?]", new_session_path
  end

  test "a signed-in user is not told their games belong to a browser" do
    browser = sign_in(users(:one))
    browser.post matches_path, params: { mode: "hotseat" }
    browser.get matches_path

    browser.assert_response :success
    assert_select browser.html_document.root, "table.games"
    assert_select browser.html_document.root, ".games__note", count: 0
  end

  test "My games is in the navigation for a guest and for a signed-in user" do
    get root_path
    assert_select "nav.masthead__nav a[href=?]", matches_path, text: "My games"

    ada = sign_in(users(:one))
    ada.get root_path
    ada.assert_select "nav.masthead__nav a[href=?]", matches_path, text: "My games"
  end

  # Rubric 14: reopening a match from My games shows the same game, and so does another
  # browser, which here is a second session with its own cookie jar.
  test "reopening a match from My games shows the same board, moves and status" do
    ada = sign_in(users(:one))
    match = online_match
    play(match, "11-15", "22-18", "15x22")

    ada.get match_path(match)
    ada.assert_response :success
    first = board_state(ada.response.body)

    ada.get matches_path
    href = href_in(ada.response.body, "tr#match-row-#{match.id} a", "Online")
    ada.get href
    ada.assert_response :success
    assert_equal first, board_state(ada.response.body), "the same match, reopened from My games"

    other = open_session
    other.get match_path(match)
    other.assert_response :success
    assert_equal first, board_state(other.response.body), "the same match in another browser"
    assert_equal %w[ 11-15 22-18 15x22 ], first[:moves]
    assert_equal match.reload.position, first[:board]
  end

  # ---- with no JavaScript at all ---------------------------------------------------------

  # Every address here is read out of the page that was served, so this walks the links a
  # visitor would click rather than the ones the test knows about (rubric 5).
  test "My games, the replay and the export are reached by plain GETs" do
    browser = guest_browser
    browser.post matches_path, params: { mode: "hotseat" }
    match = Match.order(:id).last
    play(match, "11-15", "22-18", "15x22")
    match.resign!("white")

    browser.get root_path
    my_games = href_in(browser.response.body, "nav.masthead__nav a", "My games")
    assert_equal matches_path, my_games

    browser.get my_games
    browser.assert_response :success
    row = "tr#match-row-#{match.id}"
    replay = href_in(browser.response.body, "#{row} a", "Replay")
    export = href_in(browser.response.body, "#{row} a", "Export PDN")

    browser.get replay
    browser.assert_response :success
    browser.assert_select ".replay__ply", /The starting position/
    next_ply = href_in(browser.response.body, ".replay__controls a", "Next")

    browser.get next_ply
    browser.assert_response :success
    browser.assert_select ".replay__ply", "After ply 1 of 3."
    browser.assert_select ".moves__move--latest", text: "11-15"

    browser.get export
    browser.assert_response :success
    assert_equal "text/plain; charset=utf-8", browser.response.headers["Content-Type"]
    assert_includes browser.response.body, %([GameType "21"])
    assert_equal "1-0", browser.response.body.split(/\s+/).last
  end

  # ---- the query count -----------------------------------------------------------------

  test "the page costs the same number of queries however many matches there are" do
    ada = sign_in(users(:one))
    3.times { Match.open_hotseat(user: users(:one)) }
    2.times { online_match }

    small = count_queries { ada.get matches_path }
    ada.assert_response :success

    9.times { Match.open_hotseat(user: users(:one)) }
    6.times { online_match }
    large = count_queries { ada.get matches_path }

    assert_equal small, large,
      "My games must not cost a query per row (#{small} for 5 matches, #{large} for 20)"
    # Measured at 6 for both: the session, its user, the matches, the two seat preloads and
    # one grouped count of the move rows. The ceiling is here so that a query added in the
    # view is noticed rather than merely staying constant.
    assert_operator large, :<=, 6, "the page took #{large} queries"
  end

  private
    # The address behind the link with this text, as the page wrote it.
    def href_in(body, selector, text)
      link = Nokogiri::HTML(body).css(selector).find { |anchor| anchor.text.strip == text }
      assert link, "no link reading #{text.inspect} matched #{selector.inspect}"
      link["href"]
    end

    # What a match page shows, as data: the board read off the squares, the move list and the
    # status line. Two pages showing the same game must agree on all three.
    def board_state(body)
      page = Nokogiri::HTML(body)
      # "Square 15, Red man", and on the last move's two squares "Square 15, Red man, moved
      # here", so the contents are what sits between the first comma and the next one.
      { board: page.css("##{Match::BOARD_ID} button[data-square]").sort_by { |b| b["data-square"].to_i }
                   .map { |b| b["aria-label"][/\ASquare \d+, ([^,]+)/, 1] }
                   .map { |what| { "empty" => "-", "Red man" => "r", "White man" => "w",
                                   "Red king" => "R", "White king" => "W" }.fetch(what) }.join,
        moves: page.css(".moves__move").map(&:text).reject { |text| text == "..." },
        status: page.at_css(".status__headline").text.strip }
    end

    def css_select_ids(body)
      Nokogiri::HTML(body).css("tr.games__row").map { |row| row["id"].delete_prefix("match-row-").to_i }
    end

    def count_queries(&block)
      count = 0
      counter = ->(_name, _start, _finish, _id, payload) do
        count += 1 unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:cached]
      end
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end
end
