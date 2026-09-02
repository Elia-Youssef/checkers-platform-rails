require "test_helper"

class PasswordsControllerTest < ActionDispatch::IntegrationTest
  setup { @user = User.take }

  test "new" do
    get new_password_path
    assert_response :success
  end

  test "create" do
    post passwords_path, params: { email_address: @user.email_address }
    assert_enqueued_email_with PasswordsMailer, :reset, args: [ @user ]
    assert_redirected_to new_session_path

    follow_redirect!
    assert_notice "reset instructions sent"
  end

  test "create for an unknown user redirects but sends no mail" do
    post passwords_path, params: { email_address: "missing-user@example.com" }
    assert_enqueued_emails 0
    assert_redirected_to new_session_path

    follow_redirect!
    assert_notice "reset instructions sent"
  end

  test "edit" do
    get edit_password_path(@user.password_reset_token)
    assert_response :success
  end

  test "edit with invalid password reset token" do
    get edit_password_path("invalid token")
    assert_redirected_to new_password_path

    follow_redirect!
    assert_notice "reset link is invalid"
  end

  test "update" do
    assert_changes -> { @user.reload.password_digest } do
      put password_path(@user.password_reset_token),
        params: { password: "a new password", password_confirmation: "a new password" }
      assert_redirected_to new_session_path
    end

    follow_redirect!
    assert_notice "Password has been reset"
  end

  test "update with non matching passwords" do
    token = @user.password_reset_token
    assert_no_changes -> { @user.reload.password_digest } do
      put password_path(token),
        params: { password: "a new password", password_confirmation: "another password" }
    end

    assert_response :unprocessable_content
    assert_select ".form__errors", /doesn.t match Password/
  end

  test "update with a password under the minimum length" do
    token = @user.password_reset_token
    assert_no_changes -> { @user.reload.password_digest } do
      put password_path(token), params: { password: "short", password_confirmation: "short" }
    end

    assert_response :unprocessable_content
    assert_select ".form__errors", /Password is too short/
  end

  # The four shapes a reset can arrive in without carrying a new password. The bracketed two are
  # the diff review's reproduction: `permit` drops a non-scalar parameter, so the update was a
  # validating no-op that took the success branch, destroyed every session and said
  # "Password has been reset." while the digest never changed.
  {
    "no password parameter at all" => nil,
    "a blank password" => { password: "", password_confirmation: "" },
    "an array shaped password" => { password: [ "abcdefgh" ], password_confirmation: [ "abcdefgh" ] },
    "a hash shaped password" => { password: { x: "abcdefgh" }, password_confirmation: { x: "abcdefgh" } }
  }.each do |shape, parameters|
    test "update with #{shape} changes nothing, keeps every session and shows the error" do
      token = @user.password_reset_token
      @user.sessions.create!

      assert_no_changes -> { @user.reload.password_digest } do
        assert_no_difference -> { @user.sessions.count } do
          put password_path(token), params: parameters
        end
      end

      assert_response :unprocessable_content
      assert_select ".form__errors", /Password can.t be blank/
      assert_select "form[action=?]", password_path(token)
      assert User.authenticate_by(email_address: @user.email_address, password: "password"),
        "the old password stopped working after a reset that changed nothing"
    end
  end

  test "a valid reset changes the password and signs every session out" do
    token = @user.password_reset_token
    @user.sessions.create!

    assert_changes -> { @user.reload.password_digest } do
      assert_difference -> { @user.sessions.count }, -1 do
        put password_path(token), params: { password: "a new password", password_confirmation: "a new password" }
      end
    end

    assert_redirected_to new_session_path
    assert User.authenticate_by(email_address: @user.email_address, password: "a new password")
  end

  test "a used reset link cannot be replayed" do
    token = @user.password_reset_token
    put password_path(token), params: { password: "a new password", password_confirmation: "a new password" }
    assert_redirected_to new_session_path

    @user.sessions.create!

    assert_no_changes -> { @user.reload.password_digest } do
      assert_no_difference -> { @user.sessions.count } do
        put password_path(token), params: { password: "another password", password_confirmation: "another password" }
      end
    end

    assert_redirected_to new_password_path
    follow_redirect!
    assert_notice "reset link is invalid"
  end

  private
    def assert_notice(text)
      assert_select "div", /#{text}/
    end
end
