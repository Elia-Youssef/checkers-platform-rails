require "test_helper"

# Every visitor gets a websocket: a signed-in user, a guest with the signed guest cookie, and a
# viewer with no cookies at all. Nothing is rejected for the absence of an account (see
# app/channels/application_cable/connection.rb).
class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  test "a signed in visitor is identified by the user" do
    user = users(:one)
    session = user.sessions.create!
    cookies.signed[:session_id] = session.id

    connect

    assert_equal user, connection.current_user
    assert_nil connection.current_guest_key
  end

  test "a guest is identified by the guest key" do
    cookies.signed[GuestIdentity::COOKIE_NAME] = "T5bxK1xNZ2wsAlPhb0dNKr5J9d1Y5Jsl"

    connect

    assert_nil connection.current_user
    assert_equal "T5bxK1xNZ2wsAlPhb0dNKr5J9d1Y5Jsl", connection.current_guest_key
  end

  test "a viewer with no cookies still connects" do
    connect

    assert_nil connection.current_user
    assert_nil connection.current_guest_key
  end

  test "a stale session cookie connects as a viewer instead of being rejected" do
    user = users(:one)
    session = user.sessions.create!
    cookies.signed[:session_id] = session.id
    session.destroy

    connect

    assert_nil connection.current_user
  end

  test "a signed in visitor who also carries a guest key keeps both" do
    user = users(:two)
    cookies.signed[:session_id] = user.sessions.create!.id
    cookies.signed[GuestIdentity::COOKIE_NAME] = "yaJ2M3xL0pQrStUvWxYz1234567890ab"

    connect

    assert_equal user, connection.current_user
    assert_equal "yaJ2M3xL0pQrStUvWxYz1234567890ab", connection.current_guest_key
  end
end
