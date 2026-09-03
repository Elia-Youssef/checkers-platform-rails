require "test_helper"

# Guest adoption: the matches a browser started without an account become the account's when
# that browser signs up or signs in (TASK-BRIEF 1.5, rubric 24).
#
# Everything here runs through the real endpoints with a real cookie jar, because the whole
# feature is about a cookie: the guest key that identified the browser has to still be readable
# at the moment the session is created, which is the one thing a unit test of the model cannot
# check.
class AdoptionTest < ActionDispatch::IntegrationTest
  NEW_ACCOUNT = { email_address: "newcomer@example.com", display_name: "Newcomer",
                  password: "a-good-password", password_confirmation: "a-good-password" }.freeze

  # A browser with no account, holding the guest cookie a first visit issues.
  def guest_browser
    browser = open_session
    browser.get root_path
    browser
  end

  def start_hotseat(browser)
    browser.post matches_path, params: { mode: "hotseat" }
    browser.assert_response :redirect
    Match.order(:id).last
  end

  def start_computer(browser, colour: "red", level: "easy")
    browser.post matches_path, params: { mode: "ai", colour: colour, level: level }
    browser.assert_response :redirect
    Match.order(:id).last
  end

  def sign_up(browser, **overrides)
    browser.post registration_path, params: { user: NEW_ACCOUNT.merge(overrides) }
    browser.assert_response :redirect
    User.find_by(email_address: (overrides[:email_address] || NEW_ACCOUNT[:email_address]))
  end

  def sign_in(browser, user, password: "password")
    browser.post session_path, params: { email_address: user.email_address, password: password }
    browser.assert_response :redirect
    browser
  end

  # ---- signing up --------------------------------------------------------------------

  test "signing up adopts this browser's hot-seat and computer matches" do
    browser = guest_browser
    hotseat = start_hotseat(browser)
    computer = start_computer(browser, colour: "white", level: "medium")
    key = hotseat.red_guest_key
    assert key.present?

    user = sign_up(browser)

    hotseat.reload
    assert_equal user, hotseat.red_user, "the Red seat of the hot-seat match"
    assert_equal user, hotseat.white_user, "the White seat of the hot-seat match"
    assert_nil hotseat.red_guest_key
    assert_nil hotseat.white_guest_key

    computer.reload
    assert_equal user, computer.white_user, "the human seat of the computer match"
    assert_nil computer.white_guest_key
    assert_nil computer.red_user, "the computer's seat holds nobody"
    assert_nil computer.red_guest_key
  end

  test "the adopted matches are listed in My games under the account, and name the user" do
    browser = guest_browser
    hotseat = start_hotseat(browser)
    computer = start_computer(browser, colour: "red", level: "easy")

    browser.get matches_path
    browser.assert_select "tr#match-row-#{hotseat.id} .games__opponent", text: "Guest"

    user = sign_up(browser)

    browser.get matches_path
    browser.assert_response :success
    browser.assert_select "tr#match-row-#{hotseat.id} .games__opponent", text: user.display_name
    browser.assert_select "tr#match-row-#{computer.id} .games__opponent", text: "Computer (Easy)"

    browser.get match_path(hotseat)
    browser.assert_select ".player__name", text: user.display_name, count: 2
    browser.assert_select ".player__name", text: "Guest", count: 0
  end

  test "the signed-in user can go on playing an adopted active match" do
    browser = guest_browser
    hotseat = start_hotseat(browser)
    sign_up(browser)

    browser.post match_moves_path(hotseat), params: { from: 11, to: 15 }
    browser.assert_response :redirect
    assert_equal %w[ 11-15 ], hotseat.reload.moves.map(&:pdn)
  end

  test "a second browser signed in as the same user lists the adopted matches" do
    first = guest_browser
    hotseat = start_hotseat(first)
    user = sign_up(first)

    second = open_session
    second.get root_path
    sign_in(second, user, password: NEW_ACCOUNT[:password])
    second.get matches_path
    second.assert_response :success
    second.assert_select "tr#match-row-#{hotseat.id}", count: 1
  end

  # ---- signing in --------------------------------------------------------------------

  test "signing in adopts the matches started in that browser since" do
    browser = guest_browser
    first = start_hotseat(browser)
    user = sign_up(browser)
    assert_equal user, first.reload.red_user

    browser.delete session_path
    browser.assert_response :redirect

    # Signed out, the same browser keeps its guest cookie and plays as a guest again.
    third = start_hotseat(browser)
    assert_nil third.red_user
    assert third.red_guest_key.present?

    sign_in(browser, user, password: NEW_ACCOUNT[:password])
    assert_equal user, third.reload.red_user
    assert_nil third.red_guest_key
  end

  # ---- what adoption must not touch ---------------------------------------------------

  test "an online match is untouched and another guest's matches are untouched" do
    ada = open_session
    sign_in(ada, users(:one))
    ada.post matches_path, params: { mode: "online", colour: "red" }
    ada.assert_response :redirect
    online = Match.order(:id).last

    stranger = guest_browser
    strangers_match = start_hotseat(stranger)
    stranger_key = strangers_match.red_guest_key

    browser = guest_browser
    mine = start_hotseat(browser)
    refute_equal stranger_key, mine.red_guest_key

    user = sign_up(browser)

    assert_equal users(:one), online.reload.red_user, "the online match's seat"
    assert_nil online.white_user
    assert_equal stranger_key, strangers_match.reload.red_guest_key, "another guest's match"
    assert_nil strangers_match.red_user
    assert_equal user, mine.reload.red_user
  end

  test "a seat already held by a user is left alone" do
    key = SecureRandom.urlsafe_base64(24)
    # Constructed directly: no page creates a match with one seat held by a user and the other
    # by a guest, and this is the row that proves the update rewrites a seat only when that
    # seat's own guest key is the one signing in.
    mixed = Match.create!(mode: "hotseat", status: "active",
                          red_user: users(:two), white_guest_key: key)

    adopted = Match.adopt_guest_matches(user: users(:one), guest_key: key)

    assert_equal 1, adopted
    mixed.reload
    assert_equal users(:two), mixed.red_user, "the seat that already held a user"
    assert_equal users(:one), mixed.white_user
    assert_nil mixed.white_guest_key
  end

  test "adoption is idempotent and one update covers every match" do
    browser = guest_browser
    hotseat = start_hotseat(browser)
    computer = start_computer(browser)
    key = hotseat.red_guest_key

    assert_equal 2, Match.adopt_guest_matches(user: users(:one), guest_key: key)
    before = [ hotseat, computer ].map { |match| match.reload.updated_at }

    assert_equal 0, Match.adopt_guest_matches(user: users(:one), guest_key: key)
    assert_equal before, [ hotseat, computer ].map { |match| match.reload.updated_at }

    # One statement, whatever the number of matches: the query count does not grow with them.
    third = start_hotseat(guest_browser)
    third.update_columns(red_guest_key: key, white_guest_key: key)
    queries = count_queries { Match.adopt_guest_matches(user: users(:one), guest_key: key) }
    assert_equal 1, queries, "adoption must be one UPDATE"
  end

  test "adoption does nothing without a key or a user" do
    assert_equal 0, Match.adopt_guest_matches(user: users(:one), guest_key: nil)
    assert_equal 0, Match.adopt_guest_matches(user: users(:one), guest_key: "")
    assert_equal 0, Match.adopt_guest_matches(user: nil, guest_key: "anything")
  end

  # ---- the sign-in boundary is one transaction ------------------------------------------

  # The session row and the adoption commit together or not at all. Before this, adoption ran
  # after the session had been written and outside any transaction, so a failure in it left the
  # browser signed in with its games still the guest's (session-7 audit, finding L4).
  test "a failure while adopting leaves no session row and no signed-in browser" do
    browser = guest_browser
    hotseat = start_hotseat(browser)
    key = hotseat.red_guest_key
    sessions_before = Session.count

    original = Match.method(:adopt_guest_matches)
    Match.singleton_class.define_method(:adopt_guest_matches) do |**|
      raise ActiveRecord::StatementInvalid, "adoption failed on purpose"
    end

    assert_raises(ActiveRecord::StatementInvalid) { sign_up(browser) }

    assert_equal sessions_before, Session.count, "the session row survived a failed adoption"
    hotseat.reload
    assert_nil hotseat.red_user, "a seat was written by a transaction that did not commit"
    assert_equal key, hotseat.red_guest_key, "the guest key was cleared without a commit"

    # And the browser is not signed in: the next page it asks for shows no identity, and the
    # match it started is still a guest's.
    Match.singleton_class.define_method(:adopt_guest_matches, original)
    browser.get root_path
    browser.assert_response :success
    assert_select browser.html_document.root, ".masthead__identity", 0
    browser.get match_path(hotseat)
    assert_select browser.html_document.root, ".player__name", text: "Guest", count: 2
  ensure
    Match.singleton_class.define_method(:adopt_guest_matches, original) if original
  end

  test "the guest cookie is not rotated when the browser signs in" do
    browser = guest_browser
    start_hotseat(browser)
    before = browser.cookies["guest_key"]
    assert before.present?

    sign_up(browser)

    assert_equal before, browser.cookies["guest_key"], "the guest key is the browser's, not the match's"
  end

  private
    # The SQL statements a block runs, ignoring the bookkeeping ones.
    def count_queries(&block)
      count = 0
      counter = ->(_name, _start, _finish, _id, payload) do
        count += 1 unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:cached]
      end
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end
end
