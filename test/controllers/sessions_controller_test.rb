require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup { @user = User.take }

  test "new" do
    get new_session_path
    assert_response :success
  end

  test "create with valid credentials" do
    post session_path, params: { email_address: @user.email_address, password: "password" }

    assert_redirected_to root_path
    assert cookies[:session_id]
  end

  test "create with invalid credentials" do
    post session_path, params: { email_address: @user.email_address, password: "wrong" }

    assert_redirected_to new_session_path
    assert_nil cookies[:session_id]
  end

  # A forged form can send any shape. `permit` drops a non-scalar value and
  # User.authenticate_by then raises ArgumentError for the missing key, which answered 500 on an
  # unauthenticated endpoint. It is a failed attempt, nothing more.
  [
    { email_address: "one@example.com", password: [ "x" ] },
    { email_address: "one@example.com", password: { x: "x" } },
    { email_address: [ "one@example.com" ], password: "password" },
    { email_address: { x: "one@example.com" }, password: "password" }
  ].each_with_index do |credentials, index|
    test "create with non scalar credentials #{index + 1} is a failed attempt, not a 500" do
      assert_no_difference -> { Session.count } do
        post session_path, params: credentials
      end

      assert_redirected_to new_session_path
      assert_equal "Try another email address or password.", flash[:alert]
      assert_nil cookies[:session_id].presence
    end
  end

  test "destroy" do
    sign_in_as(User.take)

    delete session_path

    assert_redirected_to new_session_path
    assert_empty cookies[:session_id]
  end

  # DELETE /session is the one action in this phase that requires an account, so signing out
  # while signed out is what makes the application write to the cookie session (the return-to
  # URL) without any help from the test. That gives these three tests a real session id to
  # watch across the sign-in and sign-out boundaries.
  test "signing in resets the cookie session, so a planted session id cannot survive it" do
    delete session_path
    planted = session[:session_id]
    assert planted.present?, "no cookie session was written before signing in"

    post session_path, params: { email_address: @user.email_address, password: "password" }

    assert_not_equal planted, session[:session_id],
      "the cookie session id was carried across the sign in boundary"
  end

  test "signing in still returns the visitor to where it was going" do
    delete session_path
    assert_redirected_to new_session_path

    post session_path, params: { email_address: @user.email_address, password: "password" }

    assert_redirected_to session_url
  end

  test "signing out empties the cookie session" do
    post session_path, params: { email_address: @user.email_address, password: "password" }
    signed_in_id = session[:session_id]
    assert signed_in_id.present?

    delete session_path

    assert_not_equal signed_in_id, session[:session_id],
      "the cookie session survived signing out"
  end

  test "signing in shows the display name and signing out takes it away" do
    post session_path, params: { email_address: @user.email_address, password: "password" }
    follow_redirect!

    assert_select ".masthead__identity", text: @user.display_name
    assert_select "form[action=?]", session_path

    delete session_path
    get root_path

    assert_select ".masthead__identity", count: 0
    assert_select "a[href=?]", new_session_path
  end
end
