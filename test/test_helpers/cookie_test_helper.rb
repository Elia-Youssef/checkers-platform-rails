# Reading and inspecting cookies the way the browser and the application see them.
#
# An integration test's `cookies` is the raw jar: signed values look like noise there. These
# helpers verify a signed value with the application's own key generator, and read the
# attributes of the Set-Cookie header the response carried.
module CookieTestHelper
  # The verified value inside a signed cookie, or nil if the signature does not check out.
  def signed_cookie(name)
    jar = ActionDispatch::Cookies::CookieJar.build(ActionDispatch::TestRequest.create, cookies.to_hash)
    jar.signed[name]
  end

  # The raw Set-Cookie line the last response wrote for this cookie, or nil if it wrote
  # none. Rack 3 returns set-cookie as an array when there is more than one.
  def set_cookie_header(name)
    Array(response.headers["set-cookie"]).flat_map { |header| header.split("\n") }
      .find { |header| header.start_with?("#{name}=") }
  end

  # The attributes of that Set-Cookie line, downcased and split, for assertions about
  # HttpOnly, SameSite and the expiry date.
  def set_cookie_attributes(name)
    header = set_cookie_header(name)
    return {} if header.nil?

    header.split("; ").drop(1).to_h do |attribute|
      key, _, value = attribute.partition("=")
      [ key.downcase, value ]
    end
  end
end

ActiveSupport.on_load(:action_dispatch_integration_test) do
  include CookieTestHelper
end
