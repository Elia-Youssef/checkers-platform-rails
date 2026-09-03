require "application_system_test_case"

# A control this application hides is hidden in a real browser that runs no JavaScript.
#
# The invite panel writes its Copy link button with the `hidden` attribute and the Stimulus
# controller removes the attribute on connect, so that a page whose script never runs never
# shows a button that cannot copy anything. That intent did not hold: [hidden] is a user-agent
# rule and application.css's bare `button` selector is an author rule, which beats it, so with
# JavaScript off the button was painted, 108 by 42.8 px, on top of the invite row and in the
# tab order (round-1 audit, finding M2). application.css now ends the argument with
# `[hidden] { display: none !important }`, and this test is what says so in a browser.
#
# The rack_test JavaScript-off tests cannot see this: that driver has no CSS engine at all and
# treats the attribute as decisive, so `assert_no_button "Copy link"` passes there whatever the
# stylesheet says. Only a real browser can grade a cascade, which is why this file runs
# Chromium with its JavaScript engine switched off instead.
#
# One consequence of that browser: turbo-rails patches `visit` in system tests to wait for
# every turbo-cable-stream-source element on the page to report itself connected, and with no
# JavaScript none ever will. So the match page here is reached by clicking, which is not
# patched, and never re-visited.
class HiddenControlsWithoutJavascriptTest < ApplicationSystemTestCase
  # The parent's driver with two things added: the command-line switch and the content setting,
  # both, because a Chromium build may honour only one of them (the audit's own probe sets both
  # as well). The rest is the parent's, repeated because driven_by replaces the registration
  # rather than adding to it.
  #
  # The name matters. Rails registers a Capybara driver under the driver type, so this class
  # and every other Chromium class would all be `:selenium`, and Capybara keeps one live
  # browser per driver name: run inside the whole suite, this test was handed the browser a
  # previous test had already started with JavaScript on, and failed for the right reason
  # (the Stimulus controller had removed the attribute it asserts is still there). A name of
  # its own gives it a browser of its own.
  driven_by :selenium, using: :headless_chrome, screen_size: WINDOW_SIZE,
    options: { name: :headless_chrome_without_javascript } do |options|
    options.binary = CHROMIUM_BINARY if File.executable?(CHROMIUM_BINARY)
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--window-size=#{WINDOW_SIZE.join(",")}")
    options.add_argument("--disable-javascript")
    options.add_preference("profile.managed_default_content_settings.javascript", 2)
  end

  def sign_in_as(user)
    visit new_session_path
    fill_in "Email address", with: user.email_address
    fill_in "Password", with: "password"
    click_button "Sign in"
    assert_selector ".masthead__identity", text: user.display_name
  end

  test "a hidden control is not displayed when no script can make it work" do
    sign_in_as users(:one)
    visit root_path
    within("#mode-online") do
      choose "online-colour-red"
      click_button "Create an online match"
    end
    assert_selector "##{Match::INVITE_ID} input.invite__field"
    match_page = current_path

    # The page really did run no script: with JavaScript on, the Stimulus controller would have
    # taken this attribute off by now (test/system/online_test.rb sees it gone).
    assert_selector ".invite__copy[hidden]", visible: :all

    # What the browser draws, measured rather than inferred from the attribute. The driver's
    # own script channel still works with the page's JavaScript switched off, which is how the
    # audit measured the button at 108 by 42.8 px before the stylesheet was fixed.
    box = evaluate_script(<<~JS)
      (function () {
        const button = document.querySelector('.invite__copy');
        const style = getComputedStyle(button);
        const rect = button.getBoundingClientRect();
        return { display: style.display, width: rect.width, height: rect.height };
      })()
    JS
    assert_equal "none", box["display"]
    assert_equal 0, box["width"].to_i
    assert_equal 0, box["height"].to_i

    # And what a player can use instead: the address as text in a field, and as a link.
    assert_no_button "Copy link"
    assert_no_selector ".invite__copy", visible: true
    assert_selector ".invite__plain a.invite__address", visible: true
    assert_button "Cancel this match"

    # Every element the application marks hidden, not just this one button: a rule that fixed
    # the copy button alone would leave the next hidden control to be found by the next
    # auditor. This match page first, since we are standing on it, then the other pages a
    # signed-in visitor sees.
    assert_nothing_hidden_is_displayed(match_page)

    [ root_path, matches_path, new_session_path ].each do |path|
      visit path
      assert_nothing_hidden_is_displayed(path)
    end
  end

  private
    def assert_nothing_hidden_is_displayed(where)
      shown = evaluate_script(<<~JS)
        Array.from(document.querySelectorAll("[hidden]"))
             .filter((element) => getComputedStyle(element).display !== "none")
             .map((element) => element.tagName + "." + element.className)
      JS
      assert_empty shown, "an element carrying the hidden attribute is displayed on #{where}"
    end
end
