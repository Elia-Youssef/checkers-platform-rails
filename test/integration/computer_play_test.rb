require "test_helper"

# The HTTP contract of playing the computer, over plain requests with no JavaScript and no
# browser: what the create form accepts, what comes back in the response that carried the
# human's move, and what each endpoint refuses.
#
#   303 See Other                the accepted action, redirecting to the match page
#   422 :unprocessable_content   an illegal leg, or an undo the rules do not allow
#   403 :forbidden               a mutating action from a session that holds no seat, which
#                                includes the human posting while the computer is to move
#
# The reply is asserted from the page the redirect leads to, which is the whole point of
# rubric item 13: no second request fetches it and nothing polls.
class ComputerPlayTest < ActionDispatch::IntegrationTest
  START = "rrrrrrrrrrrr--------wwwwwwwwwwww".freeze
  # Ten kings, White to move: the most expensive position the session-2 and session-4
  # audits could reach by legal play. The computer answers from it as Red after 4-8.
  WORST_REACHABLE = "-W-W----WWW-------RR----RR-R----".freeze

  def create_match(colour: "red", level: "medium", **options)
    get root_path
    post matches_path, params: { mode: "ai", colour: colour, level: level }, **options
    Match.order(:id).last
  end

  def leg(match, from, to, **options)
    post match_moves_path(match), params: { from: from, to: to }, **options
  end

  # The move list as the page renders it.
  def rendered_moves
    css_select(".moves__move").map { |node| node.text.strip }
  end

  def headline = css_select(".status__headline").first&.text.to_s.squish

  def search_line = css_select(".status__search").first&.text.to_s.squish

  # ---- creating (rubric 42, 13, 33) ----------------------------------------------------

  test "the home page offers a real form with a colour and a level" do
    get root_path

    assert_response :success
    assert_select "#mode-computer form[action=?][method=?]", matches_path, "post" do
      assert_select "input[name=?][value=?]", "mode", "ai"
      assert_select "input[type=radio][name=?][value=?]", "colour", "red"
      assert_select "input[type=radio][name=?][value=?]", "colour", "white"
      Draughts::AI::LEVELS.each do |level|
        assert_select "input[type=radio][name=?][value=?]", "level", level.to_s
      end
    end
  end

  test "creating as Red at each level opens a board with no move played" do
    Draughts::AI::LEVELS.each do |level|
      match = create_match(colour: "red", level: level.to_s)

      assert_response :redirect
      assert_redirected_to match_path(match)
      assert_equal "ai", match.mode
      assert_equal level.to_s, match.ai_level
      assert_equal START, match.position
      assert_equal 0, match.moves.count

      follow_redirect!
      assert_response :success
      assert_equal "Red to move", headline
      assert_select ".player__name", text: "Computer (#{Draughts::AI.label(level)})"
      assert_select ".player__name", text: "Guest"
    end
  end

  test "creating as White has the computer's first move on the board already" do
    match = create_match(colour: "white", level: "medium")

    assert_redirected_to match_path(match)
    assert_equal 1, match.moves.count
    assert_equal "red", match.moves.first.side
    assert_equal "white", match.side_to_move

    follow_redirect!
    assert_response :success
    assert_equal "White to move", headline
    assert_equal [ match.moves.first.pdn ], rendered_moves
    assert_match(/Computer \(Medium\) replied at depth 4/, search_line)
  end

  test "creating as White at Hard answers in one request with a deep first move" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    match = create_match(colour: "white", level: "hard")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal 1, match.moves.count
    assert_operator match.moves.first.ai_depth, :>=, Draughts::AI::HARD_FLOOR
    assert_operator elapsed, :<, 3.0, "the creation request took #{elapsed} s"

    follow_redirect!
    assert_equal "White to move", headline
    assert_match(/Computer \(Hard\) replied at depth (\d+)/, search_line)
    assert_operator search_line[/depth (\d+)/, 1].to_i, :>=, Draughts::AI::HARD_FLOOR
  end

  test "a colour or a level that is not one of the pinned words creates nothing" do
    [ { colour: "blue", level: "easy" },
      { colour: "red", level: "expert" },
      { colour: "", level: "" },
      { colour: [ "red" ], level: "easy" } ].each do |params|
      assert_no_difference -> { Match.count } do
        get root_path
        post matches_path, params: { mode: "ai" }.merge(params)
      end
      assert_redirected_to root_path, "#{params.inspect} did not go back to the home page"
      follow_redirect!
      assert_select ".flash--alert", /Choose/
    end
  end

  test "a missing colour and level creates nothing rather than guessing" do
    assert_no_difference -> { Match.count } do
      get root_path
      post matches_path, params: { mode: "ai" }
    end
    assert_redirected_to root_path
  end

  # ---- the reply in the same response (rubric 13, Critical) ----------------------------

  test "the reply is on the page the human's move redirects to, at all three levels" do
    Draughts::AI::LEVELS.each do |level|
      match = create_match(colour: "red", level: level.to_s)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      leg(match, 11, 15)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_response :redirect, "#{level}: the leg was refused"
      assert_operator elapsed, :<, 3.0, "#{level} took #{elapsed} s"

      follow_redirect!
      assert_response :success
      assert_equal "Red to move", headline, "#{level}: it is not the human's turn again"
      moves = rendered_moves
      assert_equal 2, moves.length, "#{level}: the reply is not on the page"
      assert_equal "11-15", moves.first
      assert_match(/Computer \(#{Draughts::AI.label(level)}\)/, search_line)

      match.reload
      assert_equal 2, match.moves.count
      assert_equal "white", match.moves.last.side
      assert_equal moves.last, match.moves.last.pdn
    end
  end

  test "Easy and Medium answer 11-15 with the same move every run" do
    %w[easy medium].each do |level|
      first = create_match(colour: "red", level: level)
      leg(first, 11, 15)
      second = create_match(colour: "red", level: level)
      leg(second, 11, 15)

      assert_equal first.reload.moves.last.pdn, second.reload.moves.last.pdn
    end
  end

  test "a Hard reply reports depth 8 or more in the panel and in the log" do
    match = create_match(colour: "red", level: "hard")

    log = capture_log { leg(match, 11, 15) }
    assert_response :redirect

    row = match.reload.moves.last
    assert_operator row.ai_depth, :>=, Draughts::AI::HARD_FLOOR
    assert_match(/\[Match #{match.id}\] computer move: hard #{Regexp.escape(row.pdn)} depth #{row.ai_depth} /, log)

    follow_redirect!
    assert_match(/Computer \(Hard\) replied at depth #{row.ai_depth} in \d+\.\d+ s/, search_line)
  end

  test "the reply is a single move row even when it is a jump sequence" do
    match = create_match(colour: "red", level: "medium")
    # White to move with exactly one legal move, the two-leg jump 24x15x8.
    match.update!(position: "--r-------r-------r----w--------",
                  start_position: "--r-------r-------r----w--------",
                  side_to_move: "white")

    assert match.reload.computer_to_move?
    match.play_computer_reply!

    get match_path(match)
    assert_response :success
    # The match was set up from a position with White to move, so PDN opens the pair with an
    # ellipsis for the Red move that was never played.
    assert_equal [ "...", "24x15x8" ], rendered_moves
    assert_equal 1, match.reload.moves.count
  end

  test "a human move that ends the match is not answered" do
    match = create_match(colour: "red", level: "easy")
    # Red to move with one White man left, and the one capture that takes it: 9x18 over 14.
    match.update!(position: "--------r----w------------------",
                  start_position: "--------r----w------------------",
                  side_to_move: "red")

    leg(match, 9, 18)
    assert_response :redirect
    match.reload

    assert_equal "finished", match.status
    assert_equal "red_won", match.result
    assert_equal 1, match.moves.count, "the computer answered a finished match"

    follow_redirect!
    assert_match(/Red wins/, headline)
  end

  test "a reply the engine cannot produce leaves the human move accepted and undoable" do
    match = create_match(colour: "red", level: "medium")

    with_failing_search { leg(match, 11, 15) }

    # The human's move stands: it was committed before the search ran.
    assert_response :redirect
    match.reload
    assert_equal 1, match.moves.count
    assert_equal "white", match.side_to_move
    assert match.computer_to_move?

    follow_redirect!
    assert_select ".controls__note", /Computer \(Medium\) has not answered your last move/

    # And Undo is the way back: one ply, because there is no reply to take back with it.
    assert_equal 1, match.undo_ply_count
    post match_undo_path(match)
    assert_response :redirect
    assert_equal 0, match.reload.moves.count
    assert_equal "red", match.side_to_move
  end

  test "a Hard reply on the audit's worst reachable position answers inside the budget" do
    # RUBRIC item 10 pins "3.0 seconds or less" for a Hard move request. The two positions the
    # item names cost 0.3 to 2.0 s of search; this is the most expensive position two audits
    # could reach by legal play (ten kings, no capture, the widest branching English draughts
    # offers), and it is the only automated assertion that bounds the request on one. The
    # human plays White, the computer answers as Red from -W-----WWWW-------RR----RR-R----,
    # about 224,800 nodes at the depth floor.
    match = create_match(colour: "white", level: "hard")
    match.moves.destroy_all
    match.update!(position: WORST_REACHABLE, start_position: WORST_REACHABLE,
                  side_to_move: "white", quiet_plies: 0)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    leg(match, 4, 8)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_response :redirect
    assert_operator elapsed, :<, 3.0,
      "the request carrying Hard's reply took #{elapsed.round(3)} s on the worst reachable position"

    row = match.reload.moves.order(:ply).last
    assert_equal "red", row.side
    assert_operator row.ai_depth, :>=, Draughts::AI::HARD_FLOOR

    follow_redirect!
    assert_match(/Computer \(Hard\) replied at depth (\d+)/, search_line)
    assert_operator search_line[/depth (\d+)/, 1].to_i, :>=, Draughts::AI::HARD_FLOOR

    # Printed so bin/ci records what the margin was on the machine that ran it.
    puts "
    [worst-position Hard request] #{elapsed.round(3)} s total, "          "search #{(row.ai_elapsed_ms / 1000.0).round(3)} s at depth #{row.ai_depth}, "          "#{row.ai_nodes} nodes"
  end

  test "a level that is not one of the pinned lower-case words creates nothing" do
    # The colour is compared against Match::SIDES exactly, and the level is compared against
    # Match::AI_LEVELS the same way. Draughts::AI.level would accept "HARD" and " hard ".
    [ "HARD", " hard ", "Hard", "hard
" ].each do |level|
      assert_no_difference -> { Match.count } do
        get root_path
        post matches_path, params: { mode: "ai", colour: "red", level: level }
      end
      assert_redirected_to root_path, "level #{level.inspect} was accepted"
    end
  end

  test "a finished computer match says the reply was the last one" do
    match = create_match(colour: "red", level: "medium")
    leg(match, 11, 15)
    follow_redirect!
    assert_match(/Computer \(Medium\) replied at depth 4/, search_line)

    post match_resignation_path(match)
    follow_redirect!

    assert_match(/White wins by resignation/, headline)
    assert_match(/Computer \(Medium\) last replied at depth 4/, search_line)
  end

  test "a side with one piece left reads 1 piece, not 1 pieces" do
    match = create_match(colour: "red", level: "easy")
    match.update!(position: "--------r----w------------------",
                  start_position: "--------r----w------------------",
                  side_to_move: "red")

    get match_path(match)
    counts = css_select(".player__count").map { |node| node.text.strip }
    assert_equal [ "1 piece", "1 piece" ], counts
  end

  # ---- refusals (rubric 4, 12) ---------------------------------------------------------

  test "an illegal leg is 422 and nothing is recorded" do
    match = create_match(colour: "red", level: "medium")
    leg(match, 11, 15)
    match.reload
    before = { position: match.position, moves: match.moves.count }

    leg(match, 9, 13)
    assert_response 422
    assert_select ".flash--alert", /not legal here/

    match.reload
    assert_equal before[:position], match.position
    assert_equal before[:moves], match.moves.count
  end

  test "the human moving one of the computer's pieces on their own turn is 422" do
    # The seat rule of phase 4: the actor holds the acting seat (Red is to move and the human
    # is Red), so this reaches the engine, and the engine refuses a piece of the other colour.
    # 403 is for an actor who does not hold the acting seat, which is the next test.
    match = create_match(colour: "red", level: "medium")

    leg(match, 23, 18)
    assert_response 422
    assert_select ".flash--alert", /not legal here/
    assert_equal 0, match.reload.moves.count
  end

  test "the human is refused with 403 while it is the computer's turn" do
    match = create_match(colour: "red", level: "medium")
    # The state a request that arrives during the search meets: the human's leg is committed
    # and the row says the computer is to move.
    match.update!(side_to_move: "white")

    leg(match, 23, 18)
    assert_response :forbidden
    assert_equal 0, match.reload.moves.count
  end

  test "another browser holds no seat and is refused every action while still seeing the board" do
    match = create_match(colour: "red", level: "medium")
    leg(match, 11, 15)

    reset!  # a fresh browser: a new guest key, no seat in this match

    get match_path(match)
    assert_response :success
    assert_select ".controls__note", /You are viewing this match/
    assert_select ".player__name", text: "Computer (Medium)"

    leg(match, 9, 13)
    assert_response :forbidden
    post match_undo_path(match)
    assert_response :forbidden
    get new_match_resignation_path(match)
    assert_response :forbidden
    post match_resignation_path(match)
    assert_response :forbidden

    assert_equal 2, match.reload.moves.count
  end

  # ---- undo (rubric 35) ----------------------------------------------------------------

  test "undo removes the human's move and the reply in one post" do
    match = create_match(colour: "red", level: "medium")
    leg(match, 11, 15)
    assert_equal 2, match.reload.moves.count

    post match_undo_path(match)
    assert_response :redirect
    match.reload

    assert_equal 0, match.moves.count
    assert_equal START, match.position
    assert_equal "red", match.side_to_move

    follow_redirect!
    assert_equal "Red to move", headline
    assert_empty rendered_moves
    assert_nil css_select(".status__search").first
  end

  test "undo is 422 and offers no button when only the computer's opening move exists" do
    match = create_match(colour: "white", level: "medium")
    assert_equal 1, match.moves.count

    get match_path(match)
    assert_select "form[action=?]", match_undo_path(match), count: 0

    post match_undo_path(match)
    assert_response 422
    assert_select ".flash--alert", /opening move cannot be taken back/
    assert_equal 1, match.reload.moves.count
  end

  # ---- resignation and Play again (rubric 26, 37) --------------------------------------

  test "resigning names the computer as the winner and offers the same game again" do
    match = create_match(colour: "red", level: "hard")
    leg(match, 11, 15)

    get new_match_resignation_path(match)
    assert_response :success
    assert_select "form[action=?]", match_resignation_path(match)

    post match_resignation_path(match)
    assert_response :redirect
    match.reload

    assert_equal "white_won", match.result
    assert_equal "resignation", match.reason

    follow_redirect!
    assert_match(/White wins by resignation/, headline)
    assert_select ".player__name", text: "Computer (Hard)"
    assert_select "form[action=?]", matches_path do
      assert_select "input[name=?][value=?]", "mode", "ai"
      assert_select "input[name=?][value=?]", "colour", "red"
      assert_select "input[name=?][value=?]", "level", "hard"
    end
  end

  test "Play again starts the same game again" do
    match = create_match(colour: "white", level: "easy")
    match.resign!("white")

    get match_path(match)
    assert_response :success

    post matches_path, params: match.play_again_params
    assert_response :redirect
    again = Match.order(:id).last

    assert_not_equal match.id, again.id
    assert_equal "ai", again.mode
    assert_equal "easy", again.ai_level
    assert_equal "white", again.human_side
    assert_equal 1, again.moves.count, "the computer opened the new game as Red too"
  end

  # ---- persistence (rubric 14) ---------------------------------------------------------

  test "the level, the seats and the search evidence survive a reload and another browser" do
    match = create_match(colour: "white", level: "medium")
    leg(match, 11, 15)
    match.reload
    expected_moves = match.moves.order(:ply).pluck(:pdn)

    get match_path(match)
    assert_equal expected_moves, rendered_moves
    first_search = search_line

    reset!
    get match_path(match)
    assert_response :success
    assert_equal expected_moves, rendered_moves
    assert_equal first_search, search_line
    assert_select ".player__name", text: "Computer (Medium)"
  end

  private
    # Makes Draughts::AI.choose raise for the duration of the block, and puts the real method
    # back. Minitest 6 dropped minitest/mock, so Object#stub no longer exists; the engine's
    # files are untouched either way, only the running process's method table.
    def with_failing_search
      original = Draughts::AI.method(:choose)
      Draughts::AI.define_singleton_method(:choose) do |*, **|
        raise Draughts::IllegalMove, "the search fell over"
      end
      yield
    ensure
      Draughts::AI.define_singleton_method(:choose, original)
    end

    # Everything the application logged while the block ran.
    def capture_log
      io = StringIO.new
      original = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(io)
      yield
      io.string
    ensure
      Rails.logger = original
    end
end
