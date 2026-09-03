require "application_system_test_case"

# Hot-seat play in a real browser: the same board and the same server, with the board Stimulus
# controller doing the selecting. The rules are still the server's, which these tests lean on
# by only ever clicking what the page offered.
class HotseatTest < ApplicationSystemTestCase
  def square(number)
    find("##{Match::BOARD_ID} button[data-square='#{number}']")
  end

  def click_square(number)
    square(number).click
  end

  def offered_targets
    all("button.square--target").map { |button| button["data-square"].to_i }.sort
  end

  def move_list
    all(".moves__move").map(&:text)
  end

  def start_hotseat
    visit root_path
    within "#mode-hotseat" do
      click_button "Start a hot-seat game"
    end
    assert_selector "##{Match::BOARD_ID}"
    Match.order(:id).last
  end

  # A quiet move: select, check the destination appeared without a page load, click it, and
  # wait until the server has written it into the move list.
  def play_quiet(pdn)
    from, to = pdn.split("-").map(&:to_i)
    click_square(from)
    assert_selector "button[data-square='#{to}'].square--target"
    click_square(to)
    assert_selector ".moves__move--latest", text: pdn
  end

  test "selecting, re-selecting and clearing happen in the page with no request" do
    match = start_hotseat
    board_url = current_url

    click_square(11)
    assert_equal [ 15, 16 ], offered_targets
    assert_equal "true", square(11)["aria-pressed"]
    assert_equal "Square 15, empty, move here", square(15)["aria-label"]

    click_square(12)
    assert_equal [ 16 ], offered_targets
    assert_equal "false", square(11)["aria-pressed"]
    assert_equal "true", square(12)["aria-pressed"]

    click_square(17)
    assert_equal [], offered_targets
    assert_equal "false", square(12)["aria-pressed"]

    click_square(10)
    assert_equal [ 14, 15 ], offered_targets

    click_square(22)
    assert_equal [], offered_targets, "clicking an opponent piece did not clear the selection"

    click_square(12)
    assert_equal [ 16 ], offered_targets
    click_square(12)
    assert_equal [], offered_targets, "clicking the selected piece did not clear it"

    assert_equal board_url, current_url, "selecting made the browser navigate"
    assert_equal 0, match.reload.moves.count, "selecting wrote something to the database"

    click_square(11)
    assert_selector "button[data-square='15'].square--target"
    click_square(15)
    assert_selector ".moves__move--latest", text: "11-15"
    assert_equal 1, match.reload.moves.count
  end

  test "the last move's two squares are tinted and nothing else is" do
    start_hotseat

    play_quiet("11-15")
    assert_selector "button.square--last-move", count: 2
    assert_equal [ 11, 15 ],
      all("button.square--last-move").map { |button| button["data-square"].to_i }.sort

    play_quiet("22-18")
    assert_selector "button.square--last-move", count: 2
    assert_equal [ 18, 22 ],
      all("button.square--last-move").map { |button| button["data-square"].to_i }.sort
  end

  test "a hot-seat game plays through a multi-jump and an undo to a result" do
    match = start_hotseat

    %w[12-16 24-20 8-12 28-24 16-19].each { |text| play_quiet(text) }
    assert_equal 5, move_list.length

    # The multi-jump: the first leg locks the board to the jumping piece.
    click_square(24)
    assert_equal [ 15 ], offered_targets
    click_square(15)

    assert_selector ".controls__note", text: "A jump is in progress"
    assert_equal [ 8 ], offered_targets
    assert_selector "button.square:not([disabled])", count: 1
    assert_no_selector "button", text: "Undo"
    assert_no_selector "a", text: "Resign"
    assert_equal 5, move_list.length

    click_square(8)

    assert_selector ".moves__move--latest", text: "24x15x8"
    assert_equal 6, move_list.length
    assert_selector ".status__headline", text: "Red to move"
    assert_equal "24x15x8", match.reload.moves.last.pdn

    # Undo takes the whole sequence back.
    click_button "Undo"

    assert_selector ".moves__move--latest", text: "16-19"
    assert_equal 5, move_list.length
    assert_selector ".status__headline", text: "White to move"
    assert_equal 5, match.reload.moves.count

    # And it can be played again.
    click_square(24)
    assert_selector "button[data-square='15'].square--target"
    click_square(15)
    assert_selector ".controls__note", text: "A jump is in progress"
    assert_selector "button[data-square='8'].square--target"
    click_square(8)
    assert_selector ".moves__move--latest", text: "24x15x8"

    assert_selector ".player__count", text: "10 pieces"

    # A result: Red is to move and resigns, so White wins.
    click_link "Resign"
    assert_selector "h1", text: "Resign this match?"
    click_button "Resign"

    assert_selector ".status__headline--result", text: "White wins by resignation"
    assert_selector ".controls__result", text: "White wins by resignation"
    assert_no_selector "button", text: "Undo"
    assert_selector "button", text: "Play again"
    assert_selector "button.square[disabled]", count: 32
    assert_equal 6, move_list.length

    match.reload
    assert_equal "finished", match.status
    assert_equal "white_won", match.result
    assert_equal "resignation", match.reason
  end

  test "play again opens a new match at the opening position" do
    first = start_hotseat
    play_quiet("11-15")
    click_link "Resign"
    assert_selector "h1", text: "Resign this match?"
    click_button "Resign"

    click_button "Play again"

    assert_selector ".moves__empty"
    assert_selector ".status__headline", text: "Red to move"
    second = Match.order(:id).last
    assert_not_equal first.id, second.id
    assert_equal "rrrrrrrrrrrr--------wwwwwwwwwwww", second.position
  end

  test "the selected piece gets an outline and its destinations get dots" do
    start_hotseat

    assert_no_selector ".square__dot", visible: true
    click_square(11)

    assert_selector "button[data-square='11'].square--selected", count: 1
    assert_selector "button.square--target .square__dot", visible: true, count: 2
    outline = page.evaluate_script(
      "getComputedStyle(document.querySelector(\"[data-square='11']\"), '::after').borderTopWidth")
    assert_equal "4px", outline, "the selected square has no outline drawn"

    click_square(17)
    assert_no_selector ".square--selected"
    assert_no_selector ".square__dot", visible: true
  end

  test "the board scales to at most 640 pixels and stays playable at a 360 pixel viewport" do
    start_hotseat

    page.current_window.resize_to(1400, 1000)
    wide = find("##{Match::BOARD_ID} .board").native.size
    assert_operator wide.width, :<=, 640
    assert_operator wide.width, :>, 320
    assert_in_delta wide.width, wide.height, 2, "the board is not square at a wide viewport"

    page.current_window.resize_to(360, 780)
    narrow = find("##{Match::BOARD_ID} .board").native.size
    assert_operator narrow.width, :<=, 360
    assert_operator narrow.width, :>, 280
    assert_in_delta narrow.width, narrow.height, 2, "the board is not square at 360 px"
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=,
      page.evaluate_script("document.documentElement.clientWidth") + 1

    click_square(11)
    assert_equal [ 15, 16 ], offered_targets
    click_square(15)
    assert_selector ".moves__move--latest", text: "11-15"
    assert_selector ".controls a", text: "Resign"
  ensure
    page.current_window.resize_to(*ApplicationSystemTestCase::WINDOW_SIZE)
  end

  test "a second browser session sees the match read-only" do
    match = start_hotseat
    play_quiet("11-15")

    using_session(:onlooker) do
      visit match_path(match)
      assert_selector ".controls__note", text: "You are viewing this match"
      assert_selector ".moves__move", text: "11-15"
      assert_selector "button.square[disabled]", count: 32
      assert_no_selector "button", text: "Undo"
      assert_no_selector "a", text: "Resign"
    end
  end
end
