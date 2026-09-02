require "test_helper"

# The authentication generator's rate limit, kept as generated: 10 attempts per 3 minutes
# per IP address (RUBRIC.md item 23). It counts in Rails.cache, so it is only real when the
# cache store is real; config/environments/test.rb sets a memory store for exactly this
# reason and test_helper.rb clears it before every test.
class SignInRateLimitTest < ActionDispatch::IntegrationTest
  ATTEMPTS_ALLOWED = 10

  setup { @user = users(:one) }

  test "the cache store behind the rate limit is real" do
    assert_not_kind_of ActiveSupport::Cache::NullStore, Rails.cache,
      "a null cache store makes every rate limit silently unlimited"
    assert_equal 1, Rails.cache.increment("rate-limit-probe", 1, expires_in: 1.minute),
      "the cache store does not count, so the rate limit cannot count either"
  end

  test "the eleventh wrong password within three minutes is refused" do
    ATTEMPTS_ALLOWED.times do |attempt|
      sign_in_with_the_wrong_password

      assert_redirected_to new_session_path
      assert_equal "Try another email address or password.", flash[:alert],
        "attempt #{attempt + 1} of #{ATTEMPTS_ALLOWED} was already rate limited"
    end

    sign_in_with_the_wrong_password

    assert_redirected_to new_session_path
    assert_equal "Try again later.", flash[:alert]
  end

  test "once the limit is reached even the right password is refused" do
    (ATTEMPTS_ALLOWED + 1).times { sign_in_with_the_wrong_password }

    post session_path, params: { email_address: @user.email_address, password: "password" }

    assert_redirected_to new_session_path
    assert_equal "Try again later.", flash[:alert]
    assert_nil cookies[:session_id].presence
  end

  test "the window is three minutes long, so a later attempt signs in again" do
    (ATTEMPTS_ALLOWED + 1).times { sign_in_with_the_wrong_password }
    assert_equal "Try again later.", flash[:alert]

    travel 4.minutes do
      post session_path, params: { email_address: @user.email_address, password: "password" }
    end

    assert_redirected_to root_path
    assert cookies[:session_id].present?
  end

  test "a client that varies X-Forwarded-For is still refused after ten attempts" do
    # The per-client limit keys on request.remote_ip, and the proxy header wins there, so this
    # loop has a fresh per-client counter on every attempt. The per-account limit is what has to
    # stop it: the eleventh attempt against one email address is refused whatever the headers say.
    addresses = (1..11).map { |n| "203.0.113.#{n}" }

    addresses.take(10).each_with_index do |address, index|
      sign_in_with_the_wrong_password(from: address)

      assert_equal "Try another email address or password.", flash[:alert],
        "attempt #{index + 1} from #{address} was already rate limited"
    end

    sign_in_with_the_wrong_password(from: addresses.last)

    assert_redirected_to new_session_path
    assert_equal "Try again later.", flash[:alert]
  end

  test "the per-client limit still bites for a client that does not forge a header" do
    other = users(:two)

    ATTEMPTS_ALLOWED.times { sign_in_with_the_wrong_password }
    # A different account, so the per-account counter for it is at zero: only the per-client
    # counter can refuse this one.
    post session_path, params: { email_address: other.email_address, password: "wrong" }

    assert_equal "Try again later.", flash[:alert]
  end

  test "each account has its own counter" do
    other = users(:two)

    (ATTEMPTS_ALLOWED + 1).times { |n| sign_in_with_the_wrong_password(from: "198.51.100.#{n}") }
    assert_equal "Try again later.", flash[:alert]

    post session_path, params: { email_address: other.email_address, password: "password" },
      headers: { "HTTP_X_FORWARDED_FOR" => "198.51.100.200" }

    assert_redirected_to root_path
    assert cookies[:session_id].present?
  end

  test "attempts with non scalar credentials count against the limits like any other" do
    # They no longer raise, so they must not be a free way to keep guessing either: ten of them
    # against one address use the account's whole window.
    ATTEMPTS_ALLOWED.times do
      post session_path, params: { email_address: @user.email_address, password: [ "wrong" ] }

      assert_equal "Try another email address or password.", flash[:alert]
    end

    post session_path, params: { email_address: @user.email_address, password: "password" }

    assert_redirected_to new_session_path
    assert_equal "Try again later.", flash[:alert]
    assert_nil cookies[:session_id].presence
  end

  private
    def sign_in_with_the_wrong_password(from: nil)
      headers = from ? { "HTTP_X_FORWARDED_FOR" => from } : {}
      post session_path, params: { email_address: @user.email_address, password: "wrong" },
        headers: headers
    end
end
