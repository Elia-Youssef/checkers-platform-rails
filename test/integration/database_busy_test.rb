require "test_helper"

# What a visitor gets when SQLite refuses a write because another connection holds the lock.
#
# SQLite has one writer. `config/database.yml` waits `timeout: 5000` for the lock and then the
# adapter raises ActiveRecord::StatementTimeout wrapping SQLite3::BusyException; nothing has
# been written when it does. Before ApplicationController rescued it, that reached the visitor
# as the generic 500 page: the round-1 audit caught one in 9224 requests, on POST /matches,
# while three lenses and one-off containers were writing at once.
#
# Holding the real lock from inside a test would block the test's own connection, so the
# refusal is injected where it actually surfaces, in the model method the request calls, by
# swapping that method for the length of one request (minitest/mock is not in the bundle).
# What is asserted is the answer: 503, Retry-After, a page saying nothing was applied, and the
# rows exactly as they were.
class DatabaseBusyTest < ActionDispatch::IntegrationTest
  # The two shapes the refusal arrives in. The first is the busy handler giving up after the
  # timeout; the second is the same refusal without that wrapper, which is what the adapter
  # raises when another connection of this process holds the lock. Raising inside the rescue
  # sets the cause, which is how ActiveRecord wraps it and how the controller recognises it.
  def busy_timeout
    raise SQLite3::BusyException, "database is locked"
  rescue SQLite3::BusyException
    raise ActiveRecord::StatementTimeout, "SQLite3::BusyException: database is locked"
  end

  def busy_statement
    raise SQLite3::BusyException, "database is locked"
  rescue SQLite3::BusyException
    raise ActiveRecord::StatementInvalid, "SQLite3::BusyException: database is locked"
  end

  def broken_sql
    raise ActiveRecord::StatementInvalid, "no such column: nonsense"
  end

  # Runs the block with `method` on `owner` replaced by one that raises `failure`, and puts the
  # original back afterwards. `owner` is the class for an instance method and its singleton
  # class for a class method.
  def while_raising(owner, method, failure)
    original = owner.instance_method(method)
    test = self
    owner.define_method(method) { |*, **| test.public_send(failure) }
    yield
  ensure
    owner.define_method(method, original)
  end

  def counts
    [ Match.count, Move.count ]
  end

  # A hot-seat match created through the application, so this session holds both its seats.
  def start_match
    get root_path
    post matches_path, params: { mode: "hotseat" }
    assert_response :redirect
    Match.order(:id).last
  end

  test "a move that meets the busy timeout answers 503 and records nothing" do
    match = start_match
    before = counts

    while_raising(Match, :play_leg!, :busy_timeout) do
      post match_moves_path(match), params: { from: 11, to: 15 }
    end

    assert_response :service_unavailable
    assert_equal "5", response.headers["Retry-After"]
    assert_match "your action was not applied", response.body
    assert_match "The server was busy", response.body
    assert_equal before, counts
    assert_equal Draughts::Position::START_BOARD, match.reload.position
    assert_equal 0, match.moves.count
  end

  test "creating a match against a busy database answers 503 and creates nothing" do
    get root_path
    before = counts

    while_raising(Match.singleton_class, :open_hotseat, :busy_timeout) do
      post matches_path, params: { mode: "hotseat" }
    end

    assert_response :service_unavailable
    assert_equal "5", response.headers["Retry-After"]
    assert_match "The server was busy", response.body
    assert_equal before, counts
  end

  test "joining a match against a busy database answers 503 and seats nobody" do
    match = Match.open_online(creator: users(:one), colour: "red")
    sign_in_as users(:two)
    before = counts

    while_raising(Match, :join!, :busy_timeout) do
      get join_path(match.invite_token)
    end

    assert_response :service_unavailable
    assert_equal "5", response.headers["Retry-After"]
    assert_equal before, counts
    match.reload
    assert_nil match.white_user
    assert_equal "waiting", match.status
  end

  test "a busy refusal without the timeout wrapper is answered the same way" do
    match = start_match

    while_raising(Match, :play_leg!, :busy_statement) do
      post match_moves_path(match), params: { from: 11, to: 15 }
    end

    assert_response :service_unavailable
    assert_equal "5", response.headers["Retry-After"]
    assert_equal Draughts::Position::START_BOARD, match.reload.position
  end

  # Turbo asks for a stream and gets a page: a 5xx is one of the two statuses Turbo renders
  # as a whole document, so the visitor sees the same words whether their browser runs
  # JavaScript or not.
  test "a Turbo request that meets the busy timeout gets the same page" do
    match = start_match

    while_raising(Match, :play_leg!, :busy_timeout) do
      post match_moves_path(match), params: { from: 11, to: 15 },
        headers: { "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml" }
    end

    assert_response :service_unavailable
    assert_equal "text/html", response.media_type
    assert_equal "5", response.headers["Retry-After"]
    assert_match "your action was not applied", response.body
  end

  # The rescue has to stay narrow: a StatementInvalid that is not the database being busy is a
  # bug in a query, and hiding it behind a friendly 503 would be worse than the 500 it earns.
  test "any other statement error still raises" do
    match = start_match

    while_raising(Match, :play_leg!, :broken_sql) do
      error = assert_raises(ActiveRecord::StatementInvalid) do
        post match_moves_path(match), params: { from: 11, to: 15 }
      end
      assert_match "no such column", error.message
    end
  end
end
