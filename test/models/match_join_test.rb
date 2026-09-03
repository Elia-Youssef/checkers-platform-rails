require "test_helper"

# The single-use rule of an invite link, decided in one place: Match#join_refusal, asked again
# by Match#join! inside the transaction that writes.
#
# The session-6 audit's finding C1 lived exactly here. join_refusal answered nil for a match
# that was already active, so a second visitor opening a forwarded link was written into the
# White seat and the player sitting in it was evicted from a running game. Only the controller
# stood in the way, with a check outside the transaction that two simultaneous opens both
# passed. Every case below is that finding's reproduction turned into an assertion.
class MatchJoinTest < ActiveSupport::TestCase
  def waiting(colour: "white")
    Match.open_online(creator: users(:one), colour: colour)
  end

  def active
    waiting.tap { |match| match.join!(users(:two)) }
  end

  # ---- the refusal predicate ------------------------------------------------------------

  test "a waiting online match with a free seat refuses nobody but its own players" do
    match = waiting

    assert_nil match.join_refusal(users(:two))
    assert_nil match.join_refusal(users(:three))
    assert_equal "you are already playing in this match", match.join_refusal(users(:one))
  end

  test "an active match refuses a join and does not answer nil" do
    match = active

    assert_equal "this match has already started", match.join_refusal(users(:three)),
      "join_refusal answered nil for an active match: a third person would take a held seat"
  end

  test "a finished and a cancelled match refuse a join" do
    finished = active
    finished.resign!("red")
    assert_equal "this match has already finished", finished.reload.join_refusal(users(:three))

    cancelled = waiting
    cancelled.cancel!
    assert_equal "this match was cancelled", cancelled.reload.join_refusal(users(:three))
  end

  test "a spent token refuses a join even if the row were put back to waiting" do
    match = waiting
    match.join!(users(:two))
    # A state no transition can produce, written directly: the guard must not depend on the
    # status alone.
    match.update_columns(status: "waiting", white_user_id: nil)

    assert_equal "the invite link has already been used", match.reload.join_refusal(users(:three))
  end

  test "a hot-seat match is not joinable at all" do
    match = Match.open_hotseat(guest_key: "g" * 32)

    assert_equal "this is not an online match", match.join_refusal(users(:two))
  end

  # ---- the transition -------------------------------------------------------------------

  test "the second player takes the free seat, spends the token and starts the match" do
    match = waiting(colour: "red")

    match.join!(users(:two))

    match.reload
    assert_equal "active", match.status
    assert_equal users(:one), match.red_user
    assert_equal users(:two), match.white_user
    assert_not_nil match.invite_token_used_at
    assert_not match.invite_open?
  end

  # This is the auditor's s6_join_model.rb scenario, assertion for assertion.
  test "a third person cannot join an active match and cannot evict a seated player" do
    match = active
    before = match.attributes

    error = assert_raises(Draughts::IllegalMove) { match.join!(users(:three)) }

    assert_equal "this match has already started", error.message
    assert_equal before, match.reload.attributes, "the refused join changed the row"
    assert_equal users(:one), match.white_user
    assert_equal users(:two), match.red_user
    assert_equal [], match.seats_held_by(user: users(:three))
  end

  test "joining a finished or a cancelled match raises and changes nothing" do
    finished = active
    finished.resign!("red")
    before = finished.reload.attributes
    assert_raises(Draughts::IllegalMove) { finished.join!(users(:three)) }
    assert_equal before, finished.reload.attributes

    cancelled = waiting
    cancelled.cancel!
    before = cancelled.reload.attributes
    assert_raises(Draughts::IllegalMove) { cancelled.join!(users(:three)) }
    assert_equal before, cancelled.reload.attributes
  end

  test "the creator cannot take the other seat in their own match" do
    match = waiting

    assert_raises(Draughts::IllegalMove) { match.join!(users(:one)) }

    match.reload
    assert_equal "waiting", match.status
    assert_nil match.red_user
    assert match.invite_open?, "the refused join spent the link"
  end

  test "a guest cannot be seated online at all" do
    match = waiting

    assert_raises(ArgumentError) { match.join!(nil) }
    assert_raises(ArgumentError) { match.join!("guest-key") }
    assert_equal "waiting", match.reload.status
  end
end
