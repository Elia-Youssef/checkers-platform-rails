require "test_helper"

# The guest cookie (TASK-BRIEF.md section 1.5): a signed, HttpOnly, SameSite=Lax cookie
# holding a random URL-safe key, created on the first visit and good for a year.
class GuestIdentityTest < ActionDispatch::IntegrationTest
  KEY_FORMAT = /\A[A-Za-z0-9_-]{32}\z/

  test "the first visit issues a signed HttpOnly guest cookie that lasts about a year" do
    get root_path

    assert_response :success
    assert set_cookie_header("guest_key"), "the first visit issued no guest cookie"

    attributes = set_cookie_attributes("guest_key")
    assert attributes.key?("httponly"), "the guest cookie is readable by JavaScript"
    assert_equal "lax", attributes["samesite"].to_s.downcase
    assert_equal "/", attributes["path"]

    expires = Time.httpdate(attributes.fetch("expires"))
    assert_in_delta 1.year.from_now.to_i, expires.to_i, 2.days.to_i,
      "the guest cookie does not last about a year"
  end

  test "the key is random, URL-safe and not readable from the raw cookie" do
    get root_path
    first_key = signed_cookie(:guest_key)

    assert_match KEY_FORMAT, first_key
    assert_not_equal first_key, cookies[:guest_key],
      "the raw cookie is the bare key, so it carries no signature"

    reset!

    get root_path
    assert_not_equal first_key, signed_cookie(:guest_key), "two visitors were given the same key"
  end

  test "a returning visitor keeps the key and the cookie is not reissued" do
    get root_path
    key = signed_cookie(:guest_key)

    get root_path

    assert_nil set_cookie_header("guest_key"), "a valid guest cookie was reissued"
    assert_equal key, signed_cookie(:guest_key)
  end

  test "a forged guest cookie is refused and replaced" do
    get root_path
    honest_key = signed_cookie(:guest_key)

    cookies[:guest_key] = "forged-guest-key"
    get root_path

    assert set_cookie_header("guest_key"), "the forged cookie was accepted"
    replacement = signed_cookie(:guest_key)
    assert_match KEY_FORMAT, replacement
    assert_not_equal "forged-guest-key", replacement
    assert_not_equal honest_key, replacement
  end

  test "editing one character of a valid guest cookie is refused" do
    get root_path
    honest_cookie = cookies[:guest_key]
    honest_key = signed_cookie(:guest_key)

    cookies[:guest_key] = honest_cookie.sub(/\A(.)/) { $1 == "A" ? "B" : "A" }
    get root_path

    assert set_cookie_header("guest_key"), "an edited cookie was accepted"
    assert_not_equal honest_key, signed_cookie(:guest_key)
  end

  test "every page issues the guest key, including the sign in page" do
    get new_session_path

    assert_response :success
    assert_match KEY_FORMAT, signed_cookie(:guest_key)
  end
end
