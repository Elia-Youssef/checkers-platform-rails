require "application_system_test_case"

# The replay in a real browser (rubric 43's replay scenario, rubric 22 and 52).
#
# Nothing on this page needs JavaScript, and that is the point of driving it with Chromium
# anyway: the four controls are ordinary links, so a browser that runs every script we ship
# still steps through the game one ply at a time and a pasted ply address opens the same
# position.
class ReplayTest < ApplicationSystemTestCase
  # Two questions asked of the page itself, because both are about layout rather than markup:
  # whether the move list is actually scrolling, and whether the highlighted entry is inside
  # the part of it a reader can see.
  OVERFLOWS = <<~JS
    (() => {
      const list = document.querySelector(".moves__list")
      return list.scrollHeight > list.clientHeight + 1
    })()
  JS

  MARK_IN_VIEW = <<~JS
    (() => {
      const box = document.querySelector(".moves__list").getBoundingClientRect()
      const mark = document.querySelector(".moves__move--latest").getBoundingClientRect()
      return mark.top >= box.top - 1 && mark.bottom <= box.bottom + 1
    })()
  JS

  # A finished hot-seat match: four plies, the fourth a capture, then Red resigns.
  #
  #   1. 11-15 22-18   2. 15x22 25x18
  #
  setup do
    @match = Match.open_hotseat(user: users(:one))
    [ "11-15", "22-18", "15x22", "25x18" ].each do |text|
      text.split(/[-x]/).map(&:to_i).each_cons(2) { |from, to| @match.play_leg!(from, to) }
    end
    @match.resign!("red")
    @match.reload
  end

  def square(number)
    find("#replay-board button[data-square='#{number}']")
  end

  def piece_on(number)
    square(number)["aria-label"]
  end

  def highlighted
    all(".moves__move--latest").map(&:text)
  end

  def tinted
    all("#replay-board button.square--last-move").map { |button| button["data-square"].to_i }.sort
  end

  def stored_position
    find(".replay__position").text
  end

  test "a finished match is replayed with the four controls" do
    visit match_path(@match)
    assert_selector ".controls__result", text: "White wins by resignation"
    click_link "Replay"

    # It opens at the start: the whole opening position, nothing highlighted, nothing tinted,
    # and the two backward controls inert.
    assert_selector ".replay__ply", text: "The starting position"
    assert_equal Draughts::Position::START_BOARD, stored_position
    assert_equal "Square 11, Red man", piece_on(11)
    assert_equal "Square 15, empty", piece_on(15)
    assert_empty highlighted
    assert_empty tinted
    assert_selector "span[data-control='first'][aria-disabled='true']"
    assert_selector "span[data-control='previous'][aria-disabled='true']"

    # Next: one ply on. The board, the highlighted move and the tint all follow.
    click_link "Next"
    assert_selector ".replay__ply", text: "After ply 1 of 4"
    assert_equal "Square 11, empty", piece_on(11)
    assert_equal "Square 15, Red man", piece_on(15)
    assert_equal [ "11-15" ], highlighted
    assert_equal [ 11, 15 ], tinted

    click_link "Next"
    assert_selector ".replay__ply", text: "After ply 2 of 4"
    assert_equal [ "22-18" ], highlighted
    assert_equal [ 18, 22 ], tinted
    assert_equal "Square 18, White man", piece_on(18)

    # Last: the final position, with the capture on the board and the two forward controls
    # inert.
    click_link "Last"
    assert_selector ".replay__ply", text: "After ply 4 of 4"
    assert_equal [ "25x18" ], highlighted
    assert_equal "Square 22, empty", piece_on(22), "the Red man on 22 was jumped"
    assert_equal @match.position, stored_position
    assert_selector "span[data-control='next'][aria-disabled='true']"
    assert_selector "span[data-control='last'][aria-disabled='true']"

    # Previous: back one ply, and the board goes back with it.
    click_link "Previous"
    assert_selector ".replay__ply", text: "After ply 3 of 4"
    assert_equal [ "15x22" ], highlighted
    assert_equal "Square 22, Red man", piece_on(22)

    # First: all the way back.
    click_link "First"
    assert_selector ".replay__ply", text: "The starting position"
    assert_equal Draughts::Position::START_BOARD, stored_position
  end

  test "a ply address opens that position directly, and one past the end opens the last" do
    visit match_replay_path(@match, ply: 3)

    assert_selector ".replay__ply", text: "After ply 3 of 4"
    assert_equal [ "15x22" ], highlighted
    assert_equal @match.moves.find_by(ply: 3).position_after, stored_position

    visit match_replay_path(@match, ply: 99)
    assert_selector ".replay__ply", text: "After ply 4 of 4"
    assert_equal @match.position, stored_position

    visit match_replay_path(@match, ply: "not-a-number")
    assert_selector ".replay__ply", text: "The starting position"
  end

  test "no square on the replay can be clicked into a move" do
    visit match_replay_path(@match, ply: 2)

    assert_equal 32, all("#replay-board button").length
    assert(all("#replay-board button").all? { |button| button.disabled? })
    assert_no_selector "turbo-cable-stream-source"
  end

  # The move list is a fixed-height scroll box, so in a long game the entry the page is talking
  # about is below the fold and a reader has to hunt for it (session-7 audit, finding L2). The
  # window is made short on purpose here: with a tall one the page could not scroll at all and
  # "the page stayed where it was" would be a fact about the window, not about the controller.
  test "the highlighted move is scrolled into the list's own box and the page is not moved" do
    long = Match.open_hotseat(user: users(:one))
    engine = Draughts::Game.new
    Match.silence_broadcasts do
      30.times do
        break if engine.finished?

        move = engine.legal_moves.first
        engine.play(move)
        move.pdn.split(/[-x]/).map(&:to_i).each_cons(2) { |from, to| long.play_leg!(from, to) }
      end
    end
    plies = long.reload.moves.count
    assert_operator plies, :>=, 24, "the list has to overflow for this test to mean anything"

    page.current_window.resize_to(1400, 520)
    visit match_replay_path(long, ply: plies)
    assert_selector ".moves__move--latest", text: long.moves.last.pdn

    assert page.evaluate_script(OVERFLOWS), "the move list does not scroll: nothing is tested here"
    assert page.evaluate_script(MARK_IN_VIEW),
      "the highlighted move is outside the visible part of the move list"
    assert_equal 0, page.evaluate_script("window.scrollY"), "the page itself was scrolled"
  ensure
    page.current_window.resize_to(*ApplicationSystemTestCase::WINDOW_SIZE)
  end

  # Rubric 52: My games to the match to the replay and back, with no error on the way.
  test "My games leads to the match and to the replay and back again" do
    visit new_session_path
    fill_in "Email address", with: users(:one).email_address
    fill_in "Password", with: "password"
    click_button "Sign in"
    assert_selector ".masthead__identity", text: "Ada"

    click_link "My games"
    assert_selector "h1", text: "My games"
    within "#match-row-#{@match.id}" do
      assert_text "White wins by resignation"
      assert_text "4 moves"
      click_link "Replay"
    end

    assert_selector ".replay__ply", text: "The starting position"
    click_link "Next"
    assert_selector ".replay__ply", text: "After ply 1 of 4"

    click_link "Back to the match"
    assert_selector "##{Match::BOARD_ID}"
    assert_selector ".controls__result", text: "White wins by resignation"

    click_link "My games"
    assert_selector "tr#match-row-#{@match.id}"
    assert_no_text "We're sorry"
  end
end
