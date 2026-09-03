require "application_system_test_case"

# Two browsers, one match: the test that proves the live layer.
#
# Both sessions are real Chromium sessions with their own cookie jar, so nothing is shared but
# the server. Nothing is ever reloaded after the match starts: every assertion about the other
# browser is an assertion that a Turbo Stream broadcast arrived over Action Cable (Solid Cable
# on SQLite) and replaced the fragment in place. The waits are measured and printed, because
# "within two seconds" is the pin (RUBRIC.md item 11) and a test that passed in ten seconds
# would not prove it.
#
# Transactional tests are on. Solid Cable writes each broadcast as a row in the cable database
# and a listener thread polls for it; inside a transactional test the pool is pinned, so the
# listener reads on the same connection as the writer and sees the row. That was measured
# before this file was written (see the session report) and every wait below re-measures it.
class OnlineTest < ApplicationSystemTestCase
  # The longest an update is allowed to take to cross from one browser to the other.
  LIVE_BUDGET = 2.0

  # Every wait one test measured, printed by that test's own teardown so the numbers reach the
  # CI log. A Minitest.after_run hook used to do it and stopped doing it: once this suite passed
  # Rails' 50 test parallelization threshold it forks workers, and after_run runs only in the
  # parent process, where nothing was ever measured. Measured on this 52 test suite before the
  # teardown below was written: 4 workers printed no summary at all, PARALLEL_WORKERS=1 printed
  # 11 waits. A forked worker writes to the parent's stdout, so a test that prints its own
  # numbers reaches the CI log either way, and the aggregate is per test because under workers
  # no single process sees every wait.
  def live_samples
    @live_samples ||= []
  end

  def square(number)
    find("##{Match::BOARD_ID} button[data-square='#{number}']")
  end

  def move_list
    all(".moves__move").map(&:text)
  end

  def sign_in_as(user)
    visit new_session_path
    fill_in "Email address", with: user.email_address
    fill_in "Password", with: "password"
    click_button "Sign in"
    assert_selector ".masthead__identity", text: user.display_name
  end

  # Waits for something to appear in the session that is *not* acting, and records how long it
  # took. The block runs assertions inside that session; Capybara's own waiting does the
  # polling. Nothing is reloaded, so what arrives can only have arrived over the socket.
  # The wait Capybara is allowed is deliberately longer than the budget being measured. With
  # both at 2.0 s (Capybara's default) a broadcast that arrived late could only ever fail inside
  # the block with "expected to find css ...", and the budget assertion below could never be the
  # one to speak (session-6 audit, finding L4). With the longer wait, a late but arriving update
  # fails here with the number it took, and one that never arrives still fails, on Capybara's
  # own timeout.
  def live(session, what)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Capybara.using_session(session) do
      Capybara.using_wait_time(LIVE_BUDGET + 3) { yield }
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    live_samples << [ what, elapsed ]
    assert_operator elapsed, :<, LIVE_BUDGET,
      "#{what} took #{format('%.3f', elapsed)} s to reach the other browser, budget #{LIVE_BUDGET} s"
    elapsed
  end

  # Plays a quiet move by clicking, in whichever session is current.
  def play_quiet(pdn)
    from, to = pdn.split("-").map(&:to_i)
    square(from).click
    assert_selector "button[data-square='#{to}'].square--target"
    square(to).click
    assert_selector ".moves__move--latest", text: pdn
  end

  # Runs after every test in this file, passing or failing, in whichever process ran it.
  teardown do
    next if live_samples.empty?

    counted = "#{live_samples.length} measured wait#{"s" unless live_samples.one?}"
    summary = +"\n    [live updates] #{name}: #{counted}, " \
      "max #{format('%.3f', live_samples.map(&:last).max)} s, budget #{LIVE_BUDGET} s\n"
    live_samples.each { |what, seconds| summary << "      #{format('%.3f', seconds)} s  #{what}\n" }
    # One write per test, so four workers printing at once cannot interleave inside a block.
    $stdout.write(summary)
  end

  # ---- rubric 11, 19, 25, 43: create, join, move, move back, draw -----------------------

  test "two players join, move and agree a draw with every update arriving live" do
    Capybara.using_session(:ada) do
      sign_in_as users(:one)
      visit root_path
      within "#mode-online" do
        choose "online-colour-red"
        click_button "Create an online match"
      end
      assert_selector "##{Match::INVITE_ID} input"
    end

    match = Match.order(:id).last
    assert_equal "waiting", match.status
    invite = nil
    Capybara.using_session(:ada) { invite = find("##{Match::INVITE_ID} input").value }
    assert_operator invite.split("/").last.length, :>=, 20

    # The copy button, with JavaScript on: the Stimulus controller takes the hidden attribute
    # off and the button copies. This is one half of a pair; the other is
    # test/system/hidden_controls_without_javascript_test.rb, where a browser running no script
    # is shown no button at all. Either half alone would pass a build that had the wrong one.
    Capybara.using_session(:ada) do
      assert_no_selector ".invite__copy[hidden]", visible: :all
      assert_button "Copy link"
      click_button "Copy link"
      assert_selector ".invite__status", text: /copied|Ctrl\+C/
    end

    # Grace opens the invite link. Ada's page must switch to the active board on its own.
    Capybara.using_session(:grace) do
      sign_in_as users(:two)
      visit invite
      assert_selector "##{Match::BOARD_ID}"
      assert_text "Waiting for Ada to move"
    end
    assert_equal "active", match.reload.status

    live(:ada, "the join") do
      assert_selector ".controls__turn", text: "Your move"
      assert_no_selector "##{Match::INVITE_ID} input"
      assert_text "Grace"
    end

    # Ada plays 11-15. Grace's board, move list, status and controls follow.
    Capybara.using_session(:ada) { play_quiet("11-15") }
    live(:grace, "Ada's 11-15") do
      assert_selector ".moves__move--latest", text: "11-15"
      assert_selector "button[data-square='15'] .piece--red"
      assert_selector ".status__headline", text: "White to move"
      assert_selector ".controls__turn", text: "Your move"
      assert_selector "button[data-square='22'][data-legal-targets]"
    end

    # And back the other way.
    Capybara.using_session(:grace) { play_quiet("22-18") }
    live(:ada, "Grace's 22-18") do
      assert_selector ".moves__move--latest", text: "22-18"
      assert_selector "button[data-square='18'] .piece--white"
      assert_selector ".status__headline", text: "Red to move"
      assert_selector ".controls__turn", text: "Your move"
    end

    # A draw offer, seen live, answered live.
    Capybara.using_session(:ada) { click_button "Offer a draw" }
    live(:grace, "Ada's draw offer") do
      assert_text "Ada (Red) has offered a draw"
      assert_button "Accept the draw"
      assert_button "Decline"
    end
    Capybara.using_session(:ada) do
      assert_text "You have offered a draw"
      assert_no_button "Offer a draw"
    end

    Capybara.using_session(:grace) { click_button "Accept the draw" }
    live(:ada, "Grace accepting the draw") do
      assert_selector ".status__headline", text: "Draw by agreement"
      assert_no_button "Offer a draw"
    end
    Capybara.using_session(:grace) { assert_selector ".status__headline", text: "Draw by agreement" }

    match.reload
    assert_equal "finished", match.status
    assert_equal "draw", match.result
    assert_equal "agreement", match.reason
    assert_equal %w[ 11-15 22-18 ], match.moves.map(&:pdn)
  end

  # ---- rubric 26, 37, 41: resignation and the rematch, both live ------------------------

  test "a resignation and the rematch link both reach the other browser live" do
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
      assert_selector ".controls__turn", text: "Waiting for Ada to move"
    end
    live(:ada, "the join, second test") { assert_selector ".controls__turn", text: "Your move" }

    # Grace resigns off turn, through the server-rendered confirmation.
    Capybara.using_session(:grace) do
      click_link "Resign"
      assert_selector "#confirm-title", text: "Resign as White?"
      click_button "Resign"
      assert_selector ".status__headline", text: "Red wins by resignation"
    end
    live(:ada, "Grace's resignation") do
      assert_selector ".status__headline", text: "Red wins by resignation"
      assert_button "Play again"
      assert_no_link "Resign"
    end

    # Ada asks for a rematch. Grace is offered it where she is standing.
    Capybara.using_session(:ada) do
      click_button "Play again"
      # Wait for the new match's own page before asking the database what was created:
      # clicking returns before Turbo has finished following the redirect.
      assert_selector "##{Match::INVITE_ID} input"
    end
    rematch = Match.order(:id).last
    assert_not_equal match.id, rematch.id
    assert_equal [ "white" ], rematch.seats_held_by(user: users(:one))

    live(:grace, "the rematch invitation") do
      assert_text "Ada has started a rematch"
      assert_link "Join the rematch"
    end
    Capybara.using_session(:grace) do
      click_link "Join the rematch"
      assert_selector ".controls__turn", text: "Your move"
    end
    rematch.reload
    assert_equal "active", rematch.status
    assert_equal users(:two), rematch.red_user
  end

  # ---- rubric 12, 41, 54: the viewer -----------------------------------------------------

  test "a viewer watches live and never gains a control" do
    match = Match.open_online(creator: users(:one), colour: "red")
    match.join!(users(:two))

    Capybara.using_session(:ada) do
      sign_in_as users(:one)
      visit match_path(match)
    end
    # Two kinds of onlooker: a third account, and a visitor with no account at all. The
    # signed-out one matters on its own: an anonymous Action Cable connection has a blank
    # identifier, so if a Turbo stream subscription depended on the connection identifying
    # somebody, this is the browser that would silently never update.
    Capybara.using_session(:onlooker) do
      sign_in_as users(:three)
      visit match_path(match)
      assert_text "You are viewing this match"
    end
    Capybara.using_session(:passerby) do
      visit match_path(match)
      assert_text "You are viewing this match"
      assert_link "Sign in"
    end

    Capybara.using_session(:ada) { play_quiet("11-15") }

    live(:onlooker, "a move seen by a signed-in viewer") do
      assert_selector ".moves__move--latest", text: "11-15"
      assert_selector "button[data-square='15'] .piece--red"
    end
    live(:passerby, "a move seen by a signed-out viewer") do
      assert_selector ".moves__move--latest", text: "11-15"
      assert_selector "button[data-square='15'] .piece--red"
    end
    [ :onlooker, :passerby ].each do |who|
      Capybara.using_session(who) do
        assert_text "You are viewing this match"
        assert_no_link "Resign"
        assert_no_button "Offer a draw"
        assert_no_selector "button.square:not([disabled])"
      end
    end
  end

  # ---- the acting browser's own controls still work after arriving by broadcast ---------
  #
  # Forms rendered for a broadcast carry no authenticity token: Rails leaves it out when there
  # is no session, which is the case outside a request. Turbo sends the token from the page's
  # own csrf-token meta tag in the X-CSRF-Token header instead, and Rails accepts either. This
  # test turns the forgery protection that the test environment switches off back on, so that
  # a control which arrived over the socket is actually submitted under the same rules as in
  # development and production.
  test "a control that arrived by broadcast still submits with forgery protection on" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    match = Match.open_online(creator: users(:one), colour: "red")
    match.join!(users(:two))

    Capybara.using_session(:ada) do
      sign_in_as users(:one)
      visit match_path(match)
    end
    Capybara.using_session(:grace) do
      sign_in_as users(:two)
      visit match_path(match)
    end

    # Ada offers a draw; the Accept button reaches Grace only as a broadcast fragment.
    Capybara.using_session(:ada) { click_button "Offer a draw" }
    live(:grace, "the Accept button, forgery protection on") { assert_button "Accept the draw" }

    Capybara.using_session(:grace) do
      click_button "Accept the draw"
      assert_selector ".status__headline", text: "Draw by agreement"
    end

    match.reload
    assert_equal "finished", match.status
    assert_equal "agreement", match.reason
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  # ---- the seat stream and the identity of the socket ------------------------------------

  # Action Cable settles who a socket belongs to when the socket opens, and a seat stream is
  # delivered only to the player holding that seat (MatchStreamAuthorization). A document that
  # opened its socket while nobody was signed in and then signed in without leaving that
  # document would therefore ask for its seat's stream as nobody, and be refused: measured
  # before this was fixed, the creator's page still read "Waiting for a second player" 6.5 s
  # after the opponent had joined. Signing in, signing up and signing out are full page loads
  # for that reason (data-turbo="false" on the three forms), which ends the document and its
  # socket at the moment the identity changes. Every navigation below is a click, because a
  # Capybara visit is a full page load and would hide exactly what this test is about.
  test "a visitor who signs in without a page load still receives their seat live" do
    watched = Match.open_online(creator: users(:three), colour: "red")

    visit match_path(watched)
    assert_selector "##{Match::BOARD_ID}"
    assert_selector "turbo-cable-stream-source", visible: :all, count: 1

    click_link "Sign in"
    fill_in "Email address", with: users(:one).email_address
    fill_in "Password", with: "password"
    click_button "Sign in"
    assert_selector ".masthead__identity", text: users(:one).display_name

    within("#mode-online") do
      choose "online-colour-red"
      click_button "Create an online match"
    end
    assert_selector "##{Match::INVITE_ID} input"
    match = Match.find(Integer(current_path[%r{/matches/(\d+)}, 1]))
    assert_equal users(:one), match.red_user

    # Turbo's stream source element carries `connected` only once Action Cable has confirmed
    # the subscription, so this one assertion is both the answer to this test's question (a
    # refused seat stream never confirms) and what makes the join below deterministic: a
    # broadcast published before the socket subscribed reaches nobody, and this page is
    # reached by clicking, which is not the `visit` turbo-rails patches to wait for exactly
    # this. Without it the test failed once in a loaded parallel run and passed alone.
    assert_selector "turbo-cable-stream-source[connected]", visible: :all

    match.join!(users(:two))
    live(Capybara.session_name, "the join, on a page reached by signing in") do
      assert_no_selector "##{Match::INVITE_ID} input"
      assert_selector ".controls__turn", text: "Your move"
      assert_text users(:two).display_name
    end
  end
end
