require "test_helper"

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  VALID = {
    email_address: "nina@example.com",
    display_name: "Nina",
    password: "correct horse",
    password_confirmation: "correct horse"
  }.freeze

  def sign_up(**overrides)
    post registration_path, params: { user: VALID.merge(overrides) }
  end

  # The same ceiling signing in has, and for the same reason: an unauthenticated POST that
  # writes a row. Ten in three minutes per apparent client, refused with the sign-in wording.
  test "the eleventh sign up within three minutes is refused" do
    10.times do |attempt|
      assert_difference -> { User.count }, 1 do
        sign_up(email_address: "nina#{attempt}@example.com")
      end
      assert_not_equal "Try again later.", flash[:alert],
        "attempt #{attempt + 1} of 10 was already rate limited"
    end

    assert_no_difference -> { User.count } do
      sign_up(email_address: "nina10@example.com")
    end

    assert_redirected_to new_registration_path
    assert_equal "Try again later.", flash[:alert]
  end

  test "the sign up window is three minutes long" do
    11.times { |attempt| sign_up(email_address: "nina#{attempt}@example.com") }
    assert_equal "Try again later.", flash[:alert]

    travel 4.minutes do
      assert_difference -> { User.count }, 1 do
        sign_up(email_address: "later@example.com")
      end
    end

    assert_redirected_to root_path
  end

  # The two limits count separately: exhausting one leaves the other alone.
  test "the sign up limit does not spend the sign in limit" do
    11.times { |attempt| sign_up(email_address: "nina#{attempt}@example.com") }
    assert_equal "Try again later.", flash[:alert]

    post session_path, params: { email_address: users(:one).email_address, password: "password" }

    assert_redirected_to root_path
    assert cookies[:session_id].present?
  end

  test "new renders the sign up form" do
    get new_registration_path

    assert_response :success
    assert_select "form[action=?]", registration_path
    assert_select "input[name=?]", "user[display_name]"
    assert_select "input[name=?]", "user[password]"
  end

  test "signing up creates the account, signs in and shows the display name" do
    assert_difference -> { User.count }, 1 do
      sign_up
    end

    assert_redirected_to root_path
    assert cookies[:session_id].present?

    user = User.find_by(email_address: "nina@example.com")
    assert_equal "Nina", user.display_name
    assert_equal user, Session.last.user

    follow_redirect!
    assert_select ".masthead__identity", text: "Nina"
    assert_select ".flash", text: /Welcome, Nina\./
  end

  test "a one character display name is refused with a field error" do
    assert_no_difference -> { User.count } do
      sign_up(display_name: "N")
    end

    assert_response :unprocessable_content
    assert_select ".form__field--invalid input[name=?]", "user[display_name]"
    assert_select "#user_display_name_error", text: /too short/
    assert_nil cookies[:session_id].presence
  end

  test "a twenty-five character display name is refused with a field error" do
    assert_no_difference -> { User.count } do
      sign_up(display_name: "N" * 25)
    end

    assert_response :unprocessable_content
    assert_select "#user_display_name_error", text: /too long/
  end

  test "a seven character password is refused with a field error" do
    assert_no_difference -> { User.count } do
      sign_up(password: "1234567", password_confirmation: "1234567")
    end

    assert_response :unprocessable_content
    assert_select "#user_password_error", text: /too short/
  end

  test "a password that does not match its confirmation is refused" do
    assert_no_difference -> { User.count } do
      sign_up(password_confirmation: "something else")
    end

    assert_response :unprocessable_content
    assert_select "#user_password_confirmation_error"
  end

  test "an email address already in use is refused" do
    assert_no_difference -> { User.count } do
      sign_up(email_address: users(:one).email_address.upcase)
    end

    assert_response :unprocessable_content
    assert_select "#user_email_address_error", text: /taken/
  end

  test "an email address that is not an email address is refused" do
    assert_no_difference -> { User.count } do
      sign_up(email_address: "not-an-email")
    end

    assert_response :unprocessable_content
    assert_select "#user_email_address_error", text: /not a valid email address/
  end

  test "the refused form keeps what was typed except the password" do
    sign_up(display_name: "N")

    assert_select "input[name=?][value=?]", "user[email_address]", "nina@example.com"
    assert_select "input[name=?][value=?]", "user[display_name]", "N"
    assert_select "input[name=?][value]", "user[password]", count: 0
  end
end
