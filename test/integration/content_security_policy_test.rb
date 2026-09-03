require "test_helper"

# The content security policy, on the response of every kind of page the application serves
# (config/initializers/content_security_policy.rb).
#
# This is the header half of the claim: that every page carries the policy, that the policy
# says what the initializer says, and that the nonce in the header is the nonce the page's own
# script tags and its csp-nonce meta tag carry, per request rather than per session. The other
# half, that no page is actually broken by the policy, is asserted in the browser by
# test/system/content_security_policy_test.rb, which reads Chromium's console.
class ContentSecurityPolicyTest < ActionDispatch::IntegrationTest
  DIRECTIVES = {
    "default-src" => "'self'",
    "img-src" => "'self' data:",
    "font-src" => "'self'",
    "object-src" => "'none'",
    "base-uri" => "'self'",
    "form-action" => "'self'",
    "frame-ancestors" => "'none'",
    "connect-src" => "'self'"
  }.freeze

  def policy
    response.headers["content-security-policy"]
  end

  def directive(name)
    policy.split(";").map(&:strip).find { |part| part.start_with?("#{name} ") || part == name }
  end

  def nonce_in_header
    directive("script-src")[/'nonce-([^']+)'/, 1]
  end

  def nonce_in_page
    css_select("meta[name=csp-nonce]").first&.[]("content")
  end

  # A hot-seat match this browser holds both seats of, so the pages that need a seat (the
  # resignation confirmation) render rather than answering 403.
  def start_match
    post matches_path, params: { mode: "hotseat" }
    assert_response :redirect
    Match.order(:id).last
  end

  test "every kind of page answers with the policy" do
    get root_path
    match = start_match
    post match_moves_path(match), params: { from: 11, to: 15 }
    finished = start_match
    finished.resign!("red")

    pages = {
      "the home page" => root_path,
      "sign in" => new_session_path,
      "sign up" => new_registration_path,
      "the password reset form" => new_password_path,
      "My games" => matches_path,
      "a match" => match_path(match),
      "a match with a square selected" => match_path(match, selected: 22),
      "the resignation confirmation" => new_match_resignation_path(match),
      "a replay" => match_replay_path(finished, ply: 1),
      "the join form" => new_join_path
    }

    pages.each do |name, path|
      get path
      assert_response :success, "#{name} did not render"
      assert_not_nil policy, "#{name} carried no content security policy"

      DIRECTIVES.each do |directive_name, expected|
        assert_equal "#{directive_name} #{expected}", directive(directive_name),
          "#{name}: #{directive_name}"
      end

      # Scripts and styles carry 'self' plus this request's nonce and nothing else.
      assert_match(/\Ascript-src 'self' 'nonce-[A-Za-z0-9+\/=]+'\z/, directive("script-src"), name)
      assert_match(/\Astyle-src 'self' 'nonce-[A-Za-z0-9+\/=]+'\z/, directive("style-src"), name)
      assert_no_match(/unsafe-inline|unsafe-eval/, policy, "#{name} loosened the policy")

      # The page and the header agree, which is what makes the importmap tags run.
      assert_equal nonce_in_header, nonce_in_page, "#{name}: the csp-nonce meta tag"
    end
  end

  test "the importmap and module tags carry the nonce the header names" do
    get root_path

    scripts = css_select("script")
    assert_equal 2, scripts.length, "expected exactly the two importmap tags"
    scripts.each do |tag|
      assert_equal nonce_in_header, tag["nonce"], "a #{tag["type"]} script had the wrong nonce"
    end
    assert_equal [ "importmap", "module" ], scripts.map { |tag| tag["type"] }
  end

  test "the nonce is fresh on every request, not per session" do
    get root_path
    first = nonce_in_header
    get root_path
    second = nonce_in_header

    assert_not_equal first, second, "the same nonce was reused for a second request"
    assert_operator Base64.decode64(first).bytesize, :>=, 16, "the nonce is under 16 bytes of entropy"
  end

  test "a PDN export carries the policy too" do
    get root_path
    match = start_match
    post match_moves_path(match), params: { from: 11, to: 15 }

    get match_path(match, format: :pdn)

    assert_response :success
    assert_equal "text/plain", response.media_type
    assert_not_nil policy
  end

  test "a refused move still carries the policy" do
    get root_path
    match = start_match

    # Red is to move, so 22 to 18 moves the other side's man: illegal, 422 (rubric 4).
    post match_moves_path(match), params: { from: 22, to: 18 }, headers: { "HTTP_ACCEPT" => "text/html" }

    assert_response :unprocessable_content
    assert_not_nil policy, "the 422 page carried no content security policy"
  end
end
