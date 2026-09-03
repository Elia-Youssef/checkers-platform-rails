require "test_helper"

# The replay: /matches/:id/replay?ply=N (TASK-BRIEF 1.7, rubric 22 and 36).
#
# The page is server-rendered and reads only the stored rows, so the assertions here are about
# two things: the right board comes back for every ply a URL can name, and no ply, however it is
# spelled, is ever an error.
class ReplayTest < ActionDispatch::IntegrationTest
  # A hot-seat match with four plies played and a fifth that takes a piece, so the board really
  # changes between the plies the tests ask for.
  #
  #   1. 11-15 22-18   2. 15x22 25x18
  #
  setup do
    @match = Match.open_hotseat(guest_key: SecureRandom.urlsafe_base64(24))
    play(@match, "11-15", "22-18", "15x22", "25x18")
    @rows = @match.moves.to_a
  end

  def play(match, *texts)
    texts.each do |text|
      text.split(/[-x]/).map(&:to_i).each_cons(2) { |from, to| match.play_leg!(from, to) }
    end
    match.reload
  end

  def board_squares
    Nokogiri::HTML(response.body).css("#replay-board button[data-square]").to_h do |button|
      [ button["data-square"].to_i, button["aria-label"] ]
    end
  end

  def tinted_squares
    Nokogiri::HTML(response.body).css("#replay-board button.square--last-move")
      .map { |button| button["data-square"].to_i }.sort
  end

  def highlighted_moves
    Nokogiri::HTML(response.body).css(".moves__move--latest").map(&:text)
  end

  def control(name)
    Nokogiri::HTML(response.body).at_css("[data-control='#{name}']")
  end

  # ---- the position at a ply -----------------------------------------------------------

  test "ply 0 is the starting position" do
    get match_replay_path(@match)

    assert_response :success
    assert_select ".replay__position", text: Draughts::Position::START_BOARD
    assert_equal "Square 11, Red man", board_squares[11]
    assert_equal "Square 15, empty", board_squares[15]
    assert_empty tinted_squares
    assert_empty highlighted_moves
    assert_select ".replay__ply", /The starting position/
  end

  test "a middle ply shows the position after that many moves" do
    get match_replay_path(@match, ply: 1)

    assert_response :success
    assert_equal @rows[0].position_after, css_position
    assert_equal "Square 11, empty", board_squares[11]
    assert_equal "Square 15, Red man", board_squares[15]
    assert_equal [ 11, 15 ], tinted_squares
    assert_equal [ "11-15" ], highlighted_moves
    assert_select ".replay__ply", "After ply 1 of 4."
  end

  test "the last ply shows the final position and the capture that made it" do
    get match_replay_path(@match, ply: 4)

    assert_response :success
    assert_equal @match.position, css_position
    assert_equal @rows[3].position_after, css_position
    assert_equal [ 18, 25 ], tinted_squares
    assert_equal [ "25x18" ], highlighted_moves
    assert_equal "Square 22, empty", board_squares[22], "the jumped man is gone"
  end

  test "a multi-jump ply is one entry in the list and tints its origin and its landing" do
    match = Match.open_hotseat(guest_key: SecureRandom.urlsafe_base64(24))
    play(match, "12-16", "24-20", "8-12", "28-24", "16-19", "24x15x8")

    get match_replay_path(match, ply: 6)

    assert_response :success
    assert_equal [ "24x15x8" ], highlighted_moves, "a whole jump sequence is one entry"
    assert_equal [ 8, 24 ], tinted_squares, "the origin and the last landing square"
    assert_equal 6, match.moves.count, "and one row"
  end

  # ---- a ply that is not a ply -----------------------------------------------------------

  test "a ply past the end clamps to the last position instead of erroring" do
    get match_replay_path(@match, ply: 99)

    assert_response :success
    assert_equal @rows.last.position_after, css_position
    assert_select ".replay__ply", "After ply 4 of 4."
  end

  test "a missing, negative, empty or non-numeric ply is the start" do
    [ nil, "-1", "", "nine", "3x", "1.5", " 2", "0x02" ].each do |ply|
      get match_replay_path(@match, ply: ply)

      assert_response :success, "ply=#{ply.inspect}"
      assert_equal Draughts::Position::START_BOARD, css_position, "ply=#{ply.inspect}"
    end
  end

  test "an enormous ply is still the last position" do
    get match_replay_path(@match, ply: "9" * 40)

    assert_response :success
    assert_equal @rows.last.position_after, css_position
  end

  # ---- the controls ----------------------------------------------------------------------

  test "First and Previous are inert at ply 0 and Next and Last lead on" do
    get match_replay_path(@match, ply: 0)

    assert_response :success
    assert_equal "SPAN", control("first").name.upcase
    assert_equal "true", control("first")["aria-disabled"]
    assert_equal "SPAN", control("previous").name.upcase
    assert_equal match_replay_path(@match, ply: 1), control("next")["href"]
    assert_equal match_replay_path(@match, ply: 4), control("last")["href"]
  end

  test "Next and Last are inert at the end and First and Previous lead back" do
    get match_replay_path(@match, ply: 4)

    assert_response :success
    assert_equal "SPAN", control("next").name.upcase
    assert_equal "true", control("next")["aria-disabled"]
    assert_equal "SPAN", control("last").name.upcase
    assert_equal match_replay_path(@match, ply: 0), control("first")["href"]
    assert_equal match_replay_path(@match, ply: 3), control("previous")["href"]
  end

  test "every control is inert in a match with no moves at all" do
    empty = Match.open_hotseat(guest_key: SecureRandom.urlsafe_base64(24))

    get match_replay_path(empty)

    assert_response :success
    %w[ first previous next last ].each do |name|
      assert_equal "SPAN", control(name).name.upcase, "#{name} in a match with no moves"
    end
    assert_select ".replay__turn", /No move has been played/
  end

  # ---- who may open it, and what it is not ------------------------------------------------

  test "the replay of a waiting online match opens at the start with nothing to step through" do
    waiting = Match.open_online(creator: users(:one), colour: "red")

    get match_replay_path(waiting)

    assert_response :success
    assert_equal Draughts::Position::START_BOARD, css_position
    assert_select ".replay__position", text: Draughts::Position::START_BOARD
  end

  test "anyone may replay a match, including a signed-out visitor and a viewer" do
    online = Match.open_online(creator: users(:one), colour: "red")
    online.join!(users(:two))
    play(online, "11-15")

    get match_replay_path(online, ply: 1)
    assert_response :success, "a signed-out visitor"

    linus = open_session
    linus.post session_path, params: { email_address: users(:three).email_address, password: "password" }
    linus.get match_replay_path(online, ply: 1)
    linus.assert_response :success, "a signed-in visitor holding no seat"
  end

  test "no square on a replayed board is a control and the page holds no form" do
    get match_replay_path(@match, ply: 2)

    page = Nokogiri::HTML(response.body)
    buttons = page.css("#replay-board button")
    assert_equal 32, buttons.length
    assert(buttons.all? { |button| button["disabled"] }, "every square must be disabled")
    assert_empty page.css("#replay-board form"), "a replayed board has no form"
    assert_empty page.css("form[action*='moves']"), "the page must not offer a move"
    assert_empty page.css("turbo-cable-stream-source"), "the replay subscribes to nothing"
  end

  test "an unknown match is 404 and not an error" do
    get "/matches/#{Match.maximum(:id).to_i + 1000}/replay"

    assert_response :not_found
  end

  # ---- rows only ---------------------------------------------------------------------------

  test "the replay does not rebuild the engine game" do
    calls = 0
    original = Draughts::Game.method(:restore)
    Draughts::Game.singleton_class.define_method(:restore) do |**arguments|
      calls += 1
      original.call(**arguments)
    end

    get match_replay_path(@match, ply: 2)

    assert_response :success
    assert_equal 0, calls, "the replay page must read the stored rows, not replay the game"
  ensure
    Draughts::Game.singleton_class.define_method(:restore, original)
  end

  test "every position the replay shows is the engine's own recomputation" do
    game = Draughts::Game.new
    boards = [ Draughts::Position::START_BOARD ]
    @rows.each do |row|
      game.play(row.pdn)
      boards << game.position.board_string
    end

    boards.each_with_index do |board, ply|
      get match_replay_path(@match, ply: ply)
      assert_equal board, css_position, "the board at ply #{ply}"
    end
  end

  private
    def css_position
      Nokogiri::HTML(response.body).at_css(".replay__position").text.strip
    end
end
