require "application_system_test_case"

# The board on a phone and on a desktop (TASK-BRIEF.md section 1.8, rubric items 44 and 46).
#
# Two viewports, 360 by 740 and 1400 by 900, and three pages: a match, a replay and My games.
# Everything here is measured in the browser rather than read out of the stylesheet, because
# the claim is about what the page renders, not about what a media query says: the board is at
# most 640 CSS pixels wide, it is square, and no page pushes the document wider than the
# viewport at 360 px. A move is played at 360 px as well, so "playable" is not an inference
# from the squares being present.
#
# The 360 px figure is the viewport width the brief fixes; 740 is a common phone height and
# nothing here depends on it. The window is restored to the suite's default at teardown so the
# other tests in the run are unaffected.
class ResponsiveTest < ApplicationSystemTestCase
  NARROW = [ 360, 740 ].freeze
  WIDE = [ 1400, 900 ].freeze
  BOARD_MAX = 640

  # Chromium's window size includes the browser chrome, so ask for a window and then check the
  # viewport the page actually got. Everything below is measured against that number.
  def resize(width, height)
    page.driver.browser.manage.window.resize_to(width, height)
    Timeout.timeout(5) { sleep 0.02 until page.evaluate_script("window.innerWidth") == width }
    width
  end

  teardown do
    page.driver.browser.manage.window.resize_to(*ApplicationSystemTestCase::WINDOW_SIZE)
  rescue StandardError
    nil
  end

  # The rendered geometry of the board on whatever page is open.
  def board_box
    page.evaluate_script(<<~JS)
      (() => {
        const board = document.querySelector(".board")
        const rect = board.getBoundingClientRect()
        const square = document.querySelector(".square").getBoundingClientRect()
        return { width: rect.width, height: rect.height, square: square.width, squareHeight: square.height }
      })()
    JS
  end

  # True when the document is wider than the viewport, which is what a horizontal page
  # scrollbar means. The skip link is parked at left: -9999px, which does not widen a
  # left-to-right document, so it does not show up here.
  def page_overflows?
    page.evaluate_script("document.documentElement.scrollWidth > window.innerWidth")
  end

  # Whatever is sticking out to the right, named, so a failure says which element to look at.
  def overflowing_elements
    page.evaluate_script(<<~JS)
      (() => {
        const limit = document.documentElement.clientWidth
        return Array.from(document.querySelectorAll("body *"))
          .filter((el) => {
            const rect = el.getBoundingClientRect()
            return rect.width > 0 && rect.right > limit + 1
          })
          .map((el) => `${el.tagName}.${el.className} right=${Math.round(el.getBoundingClientRect().right)}`)
          .slice(0, 8)
      })()
    JS
  end

  def assert_board_fits(width, label)
    box = board_box
    assert_operator box["width"], :<=, BOARD_MAX + 1,
      "#{label} at #{width} px: the board rendered #{box["width"].round(2)} px wide, over the #{BOARD_MAX} px maximum"
    assert_in_delta box["width"], box["height"], 1.0,
      "#{label} at #{width} px: the board is #{box["width"].round(2)} by #{box["height"].round(2)}, not square"
    assert_in_delta box["square"], box["squareHeight"], 1.0,
      "#{label} at #{width} px: a square is #{box["square"].round(2)} by #{box["squareHeight"].round(2)}, not square"
    assert_operator box["width"], :<=, width,
      "#{label} at #{width} px: the board is wider than the viewport"
    box
  end

  # Controls whose label is wider than the box they are drawn in. This is the other kind of
  # overflow: an input[type=submit] cannot wrap or shrink its text, so inside a flex box that
  # stretches or shrinks it the label is simply cut off, while the document stays exactly the
  # width of the viewport and nothing else in this file notices (session-8 audit, finding M1:
  # "Start a game against the computer" rendered in 263 px of box for 298 px of label).
  def clipped_controls
    page.evaluate_script(<<~JS)
      (() => {
        return Array.from(document.querySelectorAll("button, input[type=submit], .button"))
          .filter((el) => el.scrollWidth - el.clientWidth > 1)
          .map((el) => `${el.tagName} "${(el.value || el.innerText || "").trim()}" ` +
                       `box ${el.clientWidth} px, label ${el.scrollWidth} px`)
      })()
    JS
  end

  def assert_no_page_overflow(width, label)
    assert_not page_overflows?,
      "#{label} at #{width} px scrolls sideways (document #{page.evaluate_script("document.documentElement.scrollWidth")} px): " \
      "#{overflowing_elements.join(", ")}"
  end

  def sign_in_as(user)
    visit new_session_path
    fill_in "Email address", with: user.email_address
    fill_in "Password", with: "password"
    click_button "Sign in"
    assert_selector ".masthead__identity", text: user.display_name
  end

  def start_hotseat
    visit root_path
    within "#mode-hotseat" do
      click_button "Start a hot-seat game"
    end
    assert_selector "##{Match::BOARD_ID}"
    Match.order(:id).last
  end

  # A finished match to replay: 1. 11-15 22-18 2. 15x22 25x18, then Red resigns.
  def finished_match
    match = Match.open_hotseat(user: users(:one))
    [ "11-15", "22-18", "15x22", "25x18" ].each do |text|
      text.split(/[-x]/).map(&:to_i).each_cons(2) { |from, to| match.play_leg!(from, to) }
    end
    match.resign!("red")
    match.reload
  end

  test "the board fills the width at 360 px and stops at 640 px on a desktop" do
    match = start_hotseat

    width = resize(*WIDE)
    visit match_path(match)
    assert_selector "##{Match::BOARD_ID}"
    wide = assert_board_fits(width, "the match page")
    assert_no_page_overflow(width, "the match page")
    assert_in_delta BOARD_MAX, wide["width"], 1.0,
      "the board should reach its #{BOARD_MAX} px maximum on a 1400 px viewport, not #{wide["width"].round(2)} px"

    width = resize(*NARROW)
    visit match_path(match)
    assert_selector "##{Match::BOARD_ID}"
    narrow = assert_board_fits(width, "the match page")
    assert_no_page_overflow(width, "the match page")
    assert_operator narrow["width"], :>, width * 0.8,
      "at #{width} px the board only used #{narrow["width"].round(2)} px of the screen"

    # The board scaled rather than cropped: eight squares still fill it edge to edge.
    assert_in_delta narrow["width"], narrow["square"] * 8, 14.0,
      "the eight squares (#{narrow["square"].round(2)} px each) do not add up to the board"
  end

  test "a move can be played at a 360 px viewport, with the aside reachable" do
    match = start_hotseat
    width = resize(*NARROW)
    visit match_path(match)
    assert_selector "##{Match::BOARD_ID}"

    # Every part of the page a player needs is on screen without scrolling sideways.
    assert_selector ".status"
    assert_selector ".moves"
    assert_selector ".controls"
    assert_no_page_overflow(width, "the match page")

    # Select, check the server's destination appeared, and play it.
    find("##{Match::BOARD_ID} button[data-square='11']").click
    assert_selector "button[data-square='15'].square--target"
    find("##{Match::BOARD_ID} button[data-square='15']").click
    assert_selector ".moves__move--latest", text: "11-15"
    assert_equal "11-15", match.reload.moves.last.pdn

    # And the board did not grow while the page updated in place.
    assert_board_fits(width, "the match page after a move")
    assert_no_page_overflow(width, "the match page after a move")

    # A square is still a real button with its label, at a size a finger can hit.
    square = find("##{Match::BOARD_ID} button[data-square='22']")
    assert_equal "Square 22, White man", square["aria-label"]
    assert_operator board_box["square"], :>=, 24.0,
      "a square is #{board_box["square"].round(2)} px across at #{width} px"
  end

  test "the replay page holds its board at both viewports" do
    match = finished_match

    [ WIDE, NARROW ].each do |size|
      width = resize(*size)
      visit match_replay_path(match, ply: 3)
      assert_selector "#replay-board"
      assert_board_fits(width, "the replay page")
      assert_no_page_overflow(width, "the replay page")
      assert_selector ".replay__control", minimum: 2
      assert_selector ".moves__move--latest"
    end
  end

  # The three pages above are the ones with a board or a table on them. This is the sweep over
  # the rest, because a page that overflows sideways is a page nobody can read on a phone and
  # nothing else in the suite would notice.
  test "no page pushes the document wider than a 360 px viewport" do
    match = start_hotseat
    finished = finished_match
    width = resize(*NARROW)

    pages = {
      "the home page" => root_path,
      "sign in" => new_session_path,
      "sign up" => new_registration_path,
      "the password reset form" => new_password_path,
      "the join form" => new_join_path,
      "My games" => matches_path,
      "a match" => match_path(match),
      "a match with a piece selected" => match_path(match, selected: 11),
      "the resignation confirmation" => new_match_resignation_path(match),
      "a finished match" => match_path(finished),
      "a replay" => match_replay_path(finished, ply: 2)
    }

    pages.each do |name, path|
      visit path
      assert_selector "h1"
      assert_no_page_overflow(width, name)
    end
  end

  test "My games reads at 360 px without the page scrolling sideways" do
    start_hotseat
    finished_match

    width = resize(*WIDE)
    visit matches_path
    assert_selector "table.games"
    assert_no_page_overflow(width, "My games")
    assert_equal "table", page.evaluate_script('getComputedStyle(document.querySelector("table.games")).display'),
      "My games should still be a table on a desktop"

    width = resize(*NARROW)
    visit matches_path
    assert_selector "table.games"
    assert_no_page_overflow(width, "My games")

    # Collapsed: each row is a block, and each cell carries the column name it lost.
    assert_equal "block", page.evaluate_script('getComputedStyle(document.querySelector("table.games")).display')
    assert_equal '"Opponent "',
      page.evaluate_script('getComputedStyle(document.querySelector(".games__opponent"), "::before").content')

    # The table semantics survive the display change, because the roles are in the markup.
    assert_selector "table.games[role=table]"
    assert_selector "tr.games__row[role=row]"
    assert_selector "td.games__opponent[role=cell]"

    # And every row still opens its match.
    assert_selector ".games__row .games__link", minimum: 2
  end

  # The label inside the box, at both viewports. Every control the four pages a player actually
  # uses put on screen has to fit the box it is drawn in: a clipped label reads as a different
  # sentence ("Start a game against the comp") and no assertion about document width can see it.
  test "no control on the pages a player uses clips its own label" do
    match = start_hotseat
    finished = finished_match

    pages = {
      "the home page" => root_path,
      "a match" => match_path(match),
      "a replay" => match_replay_path(finished, ply: 2),
      "My games" => matches_path
    }

    [ WIDE, NARROW ].each do |size|
      width = resize(*size)

      pages.each do |name, path|
        visit path
        assert_selector "h1"
        clipped = clipped_controls
        assert_empty clipped, "#{name} at #{width} px: #{clipped.join("; ")}"
      end

      # Signed in as well, because the online card's create button only exists then, and it is
      # in the same stretching flex box as the computer card's.
      sign_in_as users(:one)
      visit root_path
      assert_selector "#mode-online button", text: "Create an online match"
      clipped = clipped_controls
      assert_empty clipped, "the home page signed in at #{width} px: #{clipped.join("; ")}"

      visit matches_path
      clipped = clipped_controls
      assert_empty clipped, "My games signed in at #{width} px: #{clipped.join("; ")}"

      click_button "Sign out"
    end
  end
end
