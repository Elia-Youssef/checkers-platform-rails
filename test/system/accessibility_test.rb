require "application_system_test_case"

# The board from the keyboard, and the focus styles (TASK-BRIEF.md section 1.8, rubric 44).
#
# Every square is a real submit button inside a form, so Enter and Space work on it without a
# single key handler in our JavaScript: the browser turns both into a click, and the board
# controller sees the same event a mouse would have produced. That is the claim this file
# checks, by never touching the mouse.
class AccessibilityTest < ApplicationSystemTestCase
  def square(number)
    find("##{Match::BOARD_ID} button[data-square='#{number}']")
  end

  def focused
    page.evaluate_script("document.activeElement.getAttribute('data-square')")
  end

  # Whatever holds the keyboard, named well enough for a failure message to be readable.
  def focused_description
    page.evaluate_script(<<~JS)
      (() => {
        const el = document.activeElement
        if (!el || el === document.body) return "BODY"
        return `${el.tagName} ${el.getAttribute("aria-label") || (el.innerText || "").trim()}`
      })()
    JS
  end

  def sign_in_as(user)
    visit new_session_path
    fill_in "Email address", with: user.email_address
    fill_in "Password", with: "password"
    click_button "Sign in"
    assert_selector ".masthead__identity", text: user.display_name
  end

  # The rendered focus ring of whatever has focus, as the browser computes it. A style that a
  # media query or a later rule had removed would show up here as "none" or a zero width.
  def focus_ring
    page.evaluate_script(<<~JS)
      (() => {
        const style = getComputedStyle(document.activeElement)
        return {
          style: style.outlineStyle,
          width: parseFloat(style.outlineWidth),
          colour: style.outlineColor,
          shadow: style.boxShadow
        }
      })()
    JS
  end

  def start_hotseat
    visit root_path
    within "#mode-hotseat" do
      click_button "Start a hot-seat game"
    end
    assert_selector "##{Match::BOARD_ID}"
    Match.order(:id).last
  end

  # A narrow window, where the move list and the controls sit under the board instead of beside
  # it, so a reader who is looking at them has the board off screen above.
  SMALL = [ 420, 640 ].freeze

  # Chromium's window includes no chrome when it is headless, but the resize is asynchronous,
  # so wait until the page has the viewport that was asked for before measuring anything in it.
  # The session that was resized is remembered for the teardown below.
  def resize(width, height)
    resized_sessions << Capybara.session_name
    page.driver.browser.manage.window.resize_to(width, height)
    Timeout.timeout(5) { sleep 0.02 until page.evaluate_script("window.innerWidth") == width }
    width
  end

  def resized_sessions
    @resized_sessions ||= []
  end

  # Capybara keeps a named session's browser alive between tests, so a small window left behind
  # would follow the next test, in this file or another one, and quietly change what it renders.
  teardown do
    resized_sessions.uniq.each do |session|
      Capybara.using_session(session) do
        page.driver.browser.manage.window.resize_to(*ApplicationSystemTestCase::WINDOW_SIZE)
      end
    end
  rescue StandardError
    nil
  end

  # Where the page is scrolled to and how far it can go, read from the browser.
  def scroll_state
    page.evaluate_script(<<~JS)
      (() => ({
        y: window.scrollY,
        max: Math.max(0, document.documentElement.scrollHeight - window.innerHeight)
      }))()
    JS
  end

  # The restore runs when Stimulus connects the replaced board, which is a beat after the new
  # markup is in the document, so waiting for the markup is not the same as waiting for it.
  def wait_for_focus(number)
    Timeout.timeout(5) { sleep 0.02 until focused == number }
  rescue Timeout::Error
    flunk "the keyboard never reached square #{number}; it is on #{focused_description}"
  end

  test "a move is played with Enter and then with Space, with no mouse" do
    match = start_hotseat

    # Enter on one of Red's men selects it. The board controller does the selecting, so nothing
    # is requested; what proves the selection is the destination appearing.
    square(11).send_keys(:enter)
    assert_selector "button[data-square='15'].square--target"
    assert_selector "button[data-square='16'].square--target"
    assert_equal "true", square(11)["aria-pressed"]
    assert_equal "11", focused, "Enter moved the focus off the square it acted on"

    # Space on a destination plays the leg. The server writes it and Turbo replaces the board.
    square(15).send_keys(:space)
    assert_selector ".moves__move--latest", text: "11-15"
    assert_equal "11-15", match.reload.moves.last.pdn
    assert_equal "rrrrrrrrrr-r--r-----wwwwwwwwwwww", match.position

    # And White's side of the board is the one that answers now.
    square(22).send_keys(:enter)
    assert_selector "button[data-square='18'].square--target"
    square(18).send_keys(:space)
    assert_selector ".moves__move--latest", text: "22-18"
    assert_equal 2, match.reload.moves.count
  end

  test "every square carries an accessible name for its number and its contents" do
    start_hotseat

    assert_equal "Square 11, Red man", square(11)["aria-label"]
    assert_equal "Square 22, White man", square(22)["aria-label"]
    assert_equal "Square 15, empty", square(15)["aria-label"]

    # A destination says what pressing it does, and says it again when it stops being one.
    square(11).send_keys(:enter)
    assert_equal "Square 15, empty, move here", square(15)["aria-label"]
    square(17).send_keys(:enter)
    assert_equal "Square 15, empty", square(15)["aria-label"]

    # The board itself is a labelled group, so a screen reader announces what it is entering.
    assert_selector ".board[role=group][aria-label='Checkers board, Red at the bottom']"
  end

  test "a focused square shows a visible ring, on an ordinary square and on a tinted one" do
    match = start_hotseat
    match.play_leg!(11, 15)
    visit match_path(match)

    square(9).send_keys("")   # focus without acting
    ring = focus_ring
    assert_equal "solid", ring["style"], "the focus ring is not drawn"
    assert_operator ring["width"], :>=, 2.0, "the focus ring is #{ring["width"]} px wide"
    assert_not_equal "none", ring["shadow"], "the halo inside the ring is missing"

    # Square 15 is the destination of the move just played, so it carries the last-move marker
    # as well; both have to be visible at once.
    square(15).send_keys("")
    assert_selector "button[data-square='15'].square--last-move"
    tinted = focus_ring
    assert_equal "solid", tinted["style"]
    assert_operator tinted["width"], :>=, 2.0
    assert_operator tinted["shadow"].scan(/rgb/).length, :>=, 2,
      "a focused last-move square should show the halo and the marker, got #{tinted["shadow"]}"
  end

  test "every control on the match page can be reached and shows focus" do
    match = start_hotseat
    match.play_leg!(11, 15)
    visit match_path(match)

    # Undo is a button_to form and Resign is a link, so both shapes are covered here, along
    # with the navigation in the masthead and the skip link's neighbours.
    [ "Undo", "Resign", "My games", "Sign in" ].each do |label|
      control = find("a, button", text: label, match: :first)
      control.send_keys("")
      ring = focus_ring
      assert_equal "solid", ring["style"], "#{label} shows no focus ring"
      assert_operator ring["width"], :>=, 2.0, "#{label}'s focus ring is #{ring["width"]} px"
    end
  end

  test "the skip link is the first thing the keyboard reaches and it works" do
    start_hotseat

    # Off screen until it has focus, on screen and usable once it does.
    link = find(".skip-link", visible: :all)
    assert_equal "Skip to the main content", link.text(:all)

    offscreen = page.evaluate_script('document.querySelector(".skip-link").getBoundingClientRect().left')
    assert_operator offscreen, :<, 0, "the skip link should be parked off screen until focused"

    page.execute_script('document.querySelector(".skip-link").focus()')
    onscreen = page.evaluate_script('document.querySelector(".skip-link").getBoundingClientRect().left')
    assert_operator onscreen, :>=, 0, "the skip link did not come on screen when focused"
    assert_selector "main#main"
  end
  # ---- rubric 44: the keyboard keeps its place across an update (session-8 audit, L2) -------

  # Every accepted leg is answered with a Turbo Stream that replaces the whole board, and the
  # button that had focus goes with it: the browser then parks focus on the body, so a keyboard
  # player walked the skip link, the brand and three navigation links again before every single
  # move. The board controller now puts the keyboard back on the board, and only when it was on
  # the board to begin with.
  #
  # With JavaScript off none of this exists and nothing changes: a leg is a form post, the
  # browser loads a new page and focus starts at the top of it, which is what a page load does
  # everywhere.
  test "focus comes back to the board after a move, at the square the piece landed on" do
    match = start_hotseat

    square(11).send_keys(:enter)
    square(15).send_keys(:space)
    assert_selector ".moves__move--latest", text: "11-15"

    # Both squares of the move carry the marker; the one the keyboard lands on is the one the
    # piece is standing on.
    assert_selector "button[data-square='11'].square--last-move"
    assert_selector "button[data-square='15'].square--last-move"
    assert_equal "15", focused,
      "after the move the keyboard is on #{focused_description}, not the square the piece landed on"

    # And the game goes on from there: White answers with the keyboard alone.
    square(22).send_keys(:enter)
    square(18).send_keys(:space)
    assert_selector ".moves__move--latest", text: "22-18"
    assert_equal "18", focused
    assert_equal 2, match.reload.moves.count
  end

  test "a locked jump puts the keyboard on the square the jump has to continue to" do
    # Started from the home page, so this browser's guest cookie holds both seats and the
    # board is live. Five quiet moves are played straight into the model to get to the jump.
    match = start_hotseat
    %w[12-16 24-20 8-12 28-24 16-19].each do |text|
      from, to = text.split("-").map(&:to_i)
      match.play_leg!(from, to)
    end
    visit match_path(match)

    # White's 24x15x8 is a two-leg jump. The first leg locks the board.
    square(24).send_keys(:enter)
    square(15).send_keys(:space)
    assert_selector ".controls__note", text: "A jump is in progress"

    # The server renders the locked piece as a disabled button (only the continuation square is
    # live, which is what stops a second piece being moved), and a disabled button cannot take
    # focus. So the square the keyboard is put on is the one square it can act on.
    assert_selector "button[data-square='15'][disabled].square--selected"
    assert_selector "button.square:not([disabled])", count: 1
    assert_equal "8", focused,
      "during the locked jump the keyboard is on #{focused_description}, not the continuation square"

    square(8).send_keys(:space)
    assert_selector ".moves__move--latest", text: "24x15x8"
    assert_equal "8", focused
    assert_equal "24x15x8", match.reload.moves.last.pdn
  end

  test "a live update does not take the keyboard away from the other player" do
    match = Match.open_online(creator: users(:one), colour: "red")
    invite = nil

    Capybara.using_session(:ada) do
      sign_in_as users(:one)
      visit match_path(match)
      invite = find("##{Match::INVITE_ID} input").value
    end

    Capybara.using_session(:grace) do
      sign_in_as users(:two)
      visit invite
      assert_selector "##{Match::BOARD_ID}"
      # Grace never touches the board. Her keyboard is on a navigation link, which is outside
      # every fragment the broadcast replaces.
      find(".masthead a", text: "My games").send_keys("")
      assert_equal "A My games", focused_description
    end

    Capybara.using_session(:ada) do
      assert_selector ".controls__turn", text: "Your move"
      square(11).send_keys(:enter)
      square(15).send_keys(:space)
      assert_selector ".moves__move--latest", text: "11-15"
      # It is White's turn now, so the server disabled every square on Ada's board and there is
      # nothing on it the keyboard can be on. Focus is not forced onto a dead control.
      assert_nil focused, "the keyboard was put on a square of a board Ada cannot play"
    end

    Capybara.using_session(:grace) do
      # Arrived over the socket, no reload: her board, move list and controls were all replaced.
      assert_selector ".moves__move--latest", text: "11-15"
      assert_equal "A My games", focused_description,
        "the live update moved Grace's keyboard to #{focused_description}"
      assert_nil focused

      # Grace replies with the mouse, and the reply reaches Ada.
      find("##{Match::BOARD_ID} button[data-square='22']").click
      find("##{Match::BOARD_ID} button[data-square='18']").click
      assert_selector ".moves__move--latest", text: "22-18"
    end

    Capybara.using_session(:ada) do
      # Ada's turn again, so the board is live again, and because her keyboard had been on the
      # board and nowhere else since, it comes back to the square White's piece landed on.
      assert_selector ".moves__move--latest", text: "22-18"
      assert_equal "18", focused,
        "when it became Ada's move again the keyboard was on #{focused_description}"
    end
  end
  # ---- rubric 44: the restore takes the keyboard back, not the page (session-8 diff review) --

  # focus() scrolls its element into view unless it is told not to, and the board is the top of
  # a match page. On a narrow window the move list and the controls sit under the board, so a
  # reader who has scrolled down to them was dragged back up by the opponent's move: an update
  # nobody asked for moved the page they were reading. Measured at 420 by 640 before the option
  # was passed, the page went from scrollY 585 to 95 when White's reply arrived. preventScroll
  # keeps the keyboard's place without taking the reader's, which is what the sibling moves
  # controller does by hand after its own scrollIntoView.
  #
  # The focus assertion is what makes the scroll assertion mean something: a restore that had
  # stopped happening would leave the page still, and pass a scroll test that proved nothing.
  test "a live update restores focus without scrolling the page away from the reader" do
    match = Match.open_online(creator: users(:one), colour: "red")
    invite = nil

    Capybara.using_session(:ada) do
      sign_in_as users(:one)
      resize(*SMALL)
      visit match_path(match)
      invite = find("##{Match::INVITE_ID} input").value
    end

    Capybara.using_session(:grace) do
      sign_in_as users(:two)
      visit invite
      assert_selector "##{Match::BOARD_ID}"
    end

    Capybara.using_session(:ada) do
      assert_selector ".controls__turn", text: "Your move"

      # With the mouse, because clicking a square focuses it: this is how a mouse player leaves
      # the keyboard on the board without ever meaning to, and the restore applies to them too.
      square(11).click
      assert_selector "button[data-square='15'].square--target"
      square(15).click
      assert_selector ".moves__move--latest", text: "11-15"

      # None of this means anything on a page that cannot scroll.
      room = scroll_state["max"]
      assert_operator room, :>, 100,
        "the match page scrolls only #{room} px at #{SMALL.join(" by ")}, so there is nothing to lose"

      page.execute_script("window.scrollTo(0, document.documentElement.scrollHeight)")
      before = scroll_state["y"]
      assert_operator before, :>, 100, "the page did not scroll down: scrollY #{before}"

      # White replies in the other browser, and the update reaches this one over the socket.
      Capybara.using_session(:grace) do
        square(22).click
        assert_selector "button[data-square='18'].square--target"
        square(18).click
        assert_selector ".moves__move--latest", text: "22-18"
      end

      assert_selector ".moves__move--latest", text: "22-18"
      assert_selector "button[data-square='18'] .piece--white"
      wait_for_focus("18")

      after = scroll_state["y"]
      assert_in_delta before, after, 1.0,
        "the live update scrolled the page from #{before} to #{after} " \
        "(#{(before - after).round} px) to bring the restored square into view"
    end
  end
  # ---- round-2 audit, M1: the highlight and the tint are said, not only drawn ---------------

  # The move list marked its latest entry with a colour and a bold weight and nothing else, and
  # the board tinted two squares whose accessible names never changed, so everything a sighted
  # reader learns at a glance about "which move was that, and where" was unavailable to a screen
  # reader. Measured before the fix on the marked entry: {"aria":null,"label":null}; on the two
  # tinted squares: ["Square 15, Red man", "Square 11, empty"].
  test "the latest move carries aria-current and the two tinted squares name themselves" do
    match = start_hotseat

    # Nothing has been played, so nothing is current and no square is an end of anything.
    assert_no_selector ".moves__move[aria-current]"
    assert_no_selector "##{Match::BOARD_ID} button[aria-label*='last move']"

    square(11).send_keys(:enter)
    square(15).send_keys(:space)
    assert_selector ".moves__move--latest", text: "11-15"

    assert_equal "step", find(".moves__move--latest")["aria-current"]
    assert_selector ".moves__move[aria-current]", count: 1
    assert_equal "Square 11, empty, last move from here", square(11)["aria-label"]
    assert_equal "Square 15, Red man, last move to here", square(15)["aria-label"]
    assert_selector "##{Match::BOARD_ID} button[aria-label*='last move']", count: 2

    # The next move moves both marks with it, and leaves none behind.
    square(22).send_keys(:enter)
    square(18).send_keys(:space)
    assert_selector ".moves__move--latest", text: "22-18"

    assert_equal "22-18", find(".moves__move[aria-current]").text
    assert_equal "Square 22, empty, last move from here", square(22)["aria-label"]
    assert_equal "Square 18, White man, last move to here", square(18)["aria-label"]
    assert_selector "##{Match::BOARD_ID} button[aria-label*='last move']", count: 2
    assert_equal 2, match.reload.moves.count
  end

  # On the replay the marked entry is the whole point of the page: it is the only thing that
  # says which of a hundred moves the board is showing.
  test "the replay names the ply it is showing in the move list and on the board" do
    match = start_hotseat
    %w[11-15 22-18 15x22 25x18].each do |text|
      text.split(/[-x]/).map(&:to_i).each_cons(2) { |from, to| match.play_leg!(from, to) }
    end

    visit match_replay_path(match, ply: 1)
    assert_equal "11-15", find(".moves__move[aria-current]").text
    assert_equal "step", find(".moves__move[aria-current]")["aria-current"]
    replay_square = ->(number) { find("#replay-board button[data-square='#{number}']") }
    assert_equal "Square 11, empty, last move from here", replay_square.call(11)["aria-label"]
    assert_equal "Square 15, Red man, last move to here", replay_square.call(15)["aria-label"]

    find("[data-control='next']").click
    assert_selector ".replay__ply", text: "After ply 2 of 4"
    assert_equal "22-18", find(".moves__move[aria-current]").text
    assert_equal "Square 22, empty, last move from here", replay_square.call(22)["aria-label"]
    assert_equal "Square 18, White man, last move to here", replay_square.call(18)["aria-label"]

    # At ply 0 there is no move to be current and no square is an end of one.
    find("[data-control='first']").click
    assert_selector ".replay__ply", text: "The starting position"
    assert_no_selector ".moves__move[aria-current]"
    assert_no_selector "#replay-board button[aria-label*='last move']"
  end

  # ---- round-2 audit, M2: a live update is announced ----------------------------------------

  # Every fragment of a match page is replaced by a Turbo Stream after every action, and the
  # only live region on the page used to be inside one of them: replacing a live region detaches
  # it and inserts a new one, which is silence, because the region a screen reader was watching
  # is gone. Measured before the fix on the opponent's page after a move:
  # {"statusStillInDocument":false,"anyAriaLive":0}. The region now lives in the layout, outside
  # every replaced id, and the announcer controller writes the status sentence into it.
  #
  # With JavaScript off there is nothing here to do: the whole page reloads and the status
  # paragraph is read where it stands.
  def announcement
    page.evaluate_script("(document.getElementById('live-announcer') || {}).textContent")
  end

  test "a move is announced in the live region on the opponent's page and a viewer's" do
    match = Match.open_online(creator: users(:one), colour: "red")
    invite = nil

    Capybara.using_session(:ada) do
      sign_in_as users(:one)
      visit match_path(match)
      invite = find("##{Match::INVITE_ID} input").value
      # A page that has just loaded says nothing: a live region is for what changes afterwards.
      assert_selector "#live-announcer"
      assert_equal "", announcement
    end

    Capybara.using_session(:grace) do
      sign_in_as users(:two)
      visit invite
      assert_selector "##{Match::BOARD_ID}"
    end

    # A guest with no seat, watching the same match.
    Capybara.using_session(:onlooker) do
      visit match_path(match)
      assert_selector ".controls__note", text: "You are viewing this match"
      assert_equal "", announcement
    end

    # Mark the region node in both watching browsers. A live region that is replaced rather
    # than written into is a new node, and a new node is what a screen reader has nothing to
    # compare against: the mark is how this test can tell the two apart.
    [ :grace, :onlooker ].each do |session|
      Capybara.using_session(session) do
        page.execute_script("document.getElementById('live-announcer').dataset.sentinel = 'kept'")
      end
    end

    Capybara.using_session(:ada) do
      assert_selector ".controls__turn", text: "Your move"
      square(11).click
      assert_selector "button[data-square='15'].square--target"
      square(15).click
      assert_selector ".moves__move--latest", text: "11-15"
    end

    # Both of the other browsers were told, over the socket, with no reload.
    [ :grace, :onlooker ].each do |session|
      Capybara.using_session(session) do
        assert_selector ".moves__move--latest", text: "11-15"
        Timeout.timeout(5) { sleep 0.02 until announcement.to_s.include?("White to move") }
        assert_equal "White to move", announcement.strip
        assert_selector "#live-announcer[aria-live='polite']"
        assert_selector "#live-announcer p", text: "White to move", visible: :all
        assert_selector "#live-announcer[data-sentinel='kept']",
          visible: :all
      end
    end

    # And the offer of a draw, which changes the status fragment without changing the turn.
    Capybara.using_session(:grace) do
      click_button "Offer a draw"
      assert_selector ".status__draw", text: "has offered a draw"
    end

    Capybara.using_session(:ada) do
      assert_selector ".status__draw", text: "has offered a draw"
      Timeout.timeout(5) { sleep 0.02 until announcement.to_s.include?("offered a draw") }
      assert_match(/White to move\. .* has offered a draw\./, announcement.strip)
    end
  end

  # ---- round-2 audit, M3: forced colours ----------------------------------------------------

  # Windows High Contrast and every other forced-colours mode repaints backgrounds, borders and
  # shadows in the user's own palette and drops box-shadows, which turned the checkerboard into
  # a plain white field: both square colours the same, the destination dots invisible and the
  # last move's ring gone. The board opts out with forced-color-adjust, because on it the
  # colours are the content.
  #
  # The emulation is a DevTools call, so this test proves it took effect before it measures
  # anything: if matchMedia says the mode is not on, the assertions below would pass on an
  # ordinary page and prove nothing at all.
  def emulate_forced_colours(value)
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia",
      features: [ { "name" => "forced-colors", "value" => value } ])
  end

  def board_colours
    page.evaluate_script(<<~JS)
      (() => {
        const dark = document.querySelector("button.square:not(.square--last-move)")
        const light = document.querySelector(".board__cell--light")
        const dot = document.querySelector(".square--target .square__dot")
        const marked = document.querySelector(".square--last-move")
        return {
          forced: window.matchMedia("(forced-colors: active)").matches,
          dark: getComputedStyle(dark).backgroundColor,
          light: getComputedStyle(light).backgroundColor,
          dot: dot ? getComputedStyle(dot).backgroundColor : null,
          dotShown: dot ? getComputedStyle(dot).display : null,
          markedBg: marked ? getComputedStyle(marked).backgroundColor : null,
          markedRing: marked ? getComputedStyle(marked).boxShadow : null
        }
      })()
    JS
  end

  test "the board keeps its two square colours, its dots and its tint in forced colours" do
    match = start_hotseat
    match.play_leg!(11, 15)
    visit match_path(match, selected: 22)
    assert_selector "button[data-square='18'].square--target"

    normal = board_colours
    assert_equal false, normal["forced"], "forced colours were already on before the emulation"

    emulate_forced_colours("active")
    forced = board_colours
    assert_equal true, forced["forced"],
      "the driver did not apply the forced-colors emulation, so this test proves nothing"

    assert_not_equal forced["dark"], forced["light"],
      "in forced colours the dark and light squares are both #{forced["dark"]}"
    assert_equal normal["dark"], forced["dark"]
    assert_equal normal["light"], forced["light"]
    assert_equal "block", forced["dotShown"], "the destination dot is not drawn"
    assert_equal normal["dot"], forced["dot"], "the destination dot lost its colour"
    assert_equal normal["markedBg"], forced["markedBg"], "the last move's square lost its fill"
    assert_not_equal "none", forced["markedRing"], "the last move's ring was dropped"
    assert_equal normal["markedRing"], forced["markedRing"]
  ensure
    emulate_forced_colours("none")
  end
end
