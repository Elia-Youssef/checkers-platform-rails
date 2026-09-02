require "application_system_test_case"

# The first system test: it proves that headless Chromium inside the container really
# renders this application and can drive a form through to a signed-in page. Every later
# system test builds on this driver setup.
class SmokeTest < ApplicationSystemTestCase
  test "the home page names the four ways to play" do
    visit root_path

    assert_selector "h1", text: "Play checkers"
    assert_selector "#mode-hotseat h2", text: "Play here"
    assert_selector "#mode-computer h2", text: "Play the computer"
    assert_selector "#mode-online h2", text: "Play online"
    assert_selector "#mode-join h2", text: "Join a match"
  end

  test "a visitor signs up and sees their display name" do
    visit root_path
    within ".masthead__nav" do
      click_on "Sign up"
    end

    assert_selector "h1", text: "Create an account"

    fill_in "user_email_address", with: "nina@example.com"
    fill_in "user_display_name", with: "Nina"
    fill_in "user_password", with: "correct horse"
    fill_in "user_password_confirmation", with: "correct horse"
    within ".form" do
      click_on "Sign up"
    end

    assert_selector ".flash", text: "Welcome, Nina."
    assert_selector ".masthead__identity", text: "Nina"
    assert_selector "h1", text: "Play checkers"
    assert_equal "Nina", User.find_by(email_address: "nina@example.com").display_name
  end

  test "a display name that is too short keeps the visitor on the form with a field error" do
    visit new_registration_path

    fill_in "user_email_address", with: "nina@example.com"
    fill_in "user_display_name", with: "N"
    fill_in "user_password", with: "correct horse"
    fill_in "user_password_confirmation", with: "correct horse"
    within ".form" do
      click_on "Sign up"
    end

    assert_selector "#user_display_name_error", text: /too short/
    assert_no_selector ".masthead__identity"
    assert_nil User.find_by(email_address: "nina@example.com")
  end
end
