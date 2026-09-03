require "application_system_test_case"

# The content security policy in a real browser: not that the header is there (the integration
# test asserts that), but that no page is broken by it.
#
# A blocked script is silent in the DOM and loud in the console, so this test reads Chromium's
# console log after each step and fails on any content security policy violation, having first
# proved that the reader works by provoking one on purpose. Every part of the page that needs
# JavaScript is exercised: the importmap and the module entry point, the board controller's
# selection, Turbo replacing fragments after a move, and the clipboard controller.
class ContentSecurityPolicySystemTest < ApplicationSystemTestCase
  VIOLATION = /Content Security Policy/i

  def console_entries
    page.driver.browser.logs.get(:browser).map { |entry| "#{entry.level}: #{entry.message}" }
  end

  def assert_no_violation(where)
    entries = console_entries.select { |line| line.match?(VIOLATION) }
    assert_empty entries, "#{where} produced a content security policy violation:\n#{entries.join("\n")}"
  end

  test "the pages that need JavaScript run under the policy" do
    visit root_path
    assert_selector "h1"
    assert_no_violation("the home page")

    within "#mode-hotseat" do
      click_button "Start a hot-seat game"
    end
    assert_selector "##{Match::BOARD_ID}"
    assert_no_violation("a new match")

    # Stimulus is running: the selection happens in the page, which only works if the module
    # script the importmap loads was allowed to execute.
    find("##{Match::BOARD_ID} button[data-square='11']").click
    assert_selector "button[data-square='15'].square--target"
    assert_equal "true", find("##{Match::BOARD_ID} button[data-square='11']")["aria-pressed"]
    assert_no_violation("selecting a piece")

    # Turbo is running: the move replaces four fragments without a page load.
    find("##{Match::BOARD_ID} button[data-square='15']").click
    assert_selector ".moves__move--latest", text: "11-15"
    assert_no_violation("playing a move")

    visit matches_path
    assert_selector "h1", text: "My games"
    assert_no_violation("My games")
  end

  test "the live board and its websocket run under the policy" do
    ada = users(:one)
    grace = users(:two)

    Capybara.using_session(:ada) do
      sign_in_through_the_form(ada)
      visit root_path
      within "#mode-online" do
        choose "online-colour-red"
        click_button "Create an online match"
      end
      assert_selector "##{Match::INVITE_ID} input"
      assert_no_violation("the waiting page")
    end

    match = Match.order(:id).last

    Capybara.using_session(:grace) do
      sign_in_through_the_form(grace)
      visit join_path(match.invite_token)
      assert_selector "##{Match::BOARD_ID}"
      assert_no_violation("the joiner's board")
    end

    # The creator's page moved to the live board on its own: the websocket connected, which is
    # what connect-src 'self' has to allow.
    Capybara.using_session(:ada) do
      assert_selector "##{Match::BOARD_ID} button[data-square='11']:not([disabled])"
      assert_no_violation("the creator's live board")

      # The clipboard controller is loaded on this page as well.
      find("##{Match::BOARD_ID} button[data-square='11']").click
      assert_selector "button[data-square='15'].square--target"
      find("##{Match::BOARD_ID} button[data-square='15']").click
      assert_selector ".moves__move--latest", text: "11-15"
      assert_no_violation("the creator's move")
    end

    Capybara.using_session(:grace) do
      assert_selector ".moves__move--latest", text: "11-15"
      assert_no_violation("the move arriving over the socket")
    end
  end

  # The negative control, kept in the suite: the reader above only means something if it can
  # see a violation. This one is provoked deliberately, so the test that no page produces one
  # is not a test that never fires.
  test "an inline script without the nonce is blocked, and the console says so" do
    visit root_path
    assert_selector "h1"

    page.execute_script(<<~JS)
      const script = document.createElement("script")
      script.textContent = "window.__cspControl = 'ran'"
      document.body.appendChild(script)
    JS

    assert_nil page.evaluate_script("window.__cspControl || null"),
      "an inline script with no nonce ran: the policy is not being enforced"

    entries = console_entries.select { |line| line.match?(VIOLATION) }
    assert_equal 1, entries.length, "expected exactly one violation in the console"
    assert_match(/Executing inline script violates/, entries.first)
    assert_match(/script-src 'self' 'nonce-/, entries.first)
  end

  private
    def sign_in_through_the_form(user)
      visit new_session_path
      fill_in "Email address", with: user.email_address
      fill_in "Password", with: "password"
      click_button "Sign in"
      assert_selector ".masthead__identity", text: user.display_name
    end
end
