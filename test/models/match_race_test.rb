require "test_helper"

# Two people clicking at the same moment.
#
# Transactional tests are off here on purpose: they pin one connection for every thread, which
# would serialize the threads by itself and prove nothing. These tests take real connections out
# of the pool, so the two writers really do contend, and what keeps them apart is the thing that
# has to: one transaction per transition, opened as BEGIN IMMEDIATE by the SQLite adapter, with
# the row re-read and locked inside it.
#
# Both cases are session-6 audit findings. C1: two opens of one invite link both seated, and the
# creator was evicted from a running game (6 of 8 rounds over HTTP). H1: both players pressing
# Play again created two rematches and one was orphaned with a live invite token (9 of 10).
class MatchRaceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  ROUNDS = 6

  # The query cache is per connection and is cleared by that connection's own writes. These
  # tests write from other connections, so a count taken before a race would still be served
  # from the cache afterwards and the test would read a row that exists as missing. Measured:
  # Match.count said 1 while Match.exists?(rematch.id) said true. Off, so every read below is a
  # read of the database.
  setup { ActiveRecord::Base.connection.disable_query_cache! }

  teardown do
    # Nothing here runs in a transaction, so the rows have to go, or the next test's fixture
    # load cannot delete the users these rows point at.
    Move.delete_all
    Match.update_all(rematch_match_id: nil)
    Match.delete_all
  end

  # Runs the blocks at once and returns their values, an exception counting as its value.
  def race(*blocks)
    barrier = Concurrent::CyclicBarrier.new(blocks.length)
    threads = blocks.map do |block|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait
          begin
            block.call
          rescue StandardError => e
            e
          end
        end
      end
    end
    threads.map(&:value)
  end

  test "two people opening the same invite link: one is seated, the other is refused" do
    seated_counts = []

    ROUNDS.times do
      match = Match.open_online(creator: users(:one), colour: "white")
      before = Match.count

      results = race(-> { Match.find(match.id).join!(users(:two)) },
                     -> { Match.find(match.id).join!(users(:three)) })

      match.reload
      joined = results.count { |r| r.is_a?(Match) }
      refused = results.select { |r| r.is_a?(Draughts::IllegalMove) }

      assert_equal 1, joined, "both openings of one link were accepted: #{results.inspect}"
      assert_equal 1, refused.length, "the loser was not refused: #{results.inspect}"
      assert_equal "this match has already started", refused.first.message
      assert_equal "active", match.status
      assert_equal users(:one), match.white_user, "the creator was evicted from their own seat"
      assert_includes [ users(:two), users(:three) ], match.red_user
      assert_not_nil match.invite_token_used_at
      assert_equal before, Match.count, "a race created a row"
      seated_counts << [ match.red_user.id, match.white_user.id ].uniq.length
    end

    assert_equal [ 2 ] * ROUNDS, seated_counts, "a match ended up with one person in both seats"
  end

  test "both players pressing Play again at once end in one rematch, not two" do
    ROUNDS.times do
      match = Match.open_online(creator: users(:one), colour: "red")
      match.join!(users(:two))
      match.resign!("red")
      before = Match.count

      results = race(-> { Match.find(match.id).start_rematch!(user: users(:one)) },
                     -> { Match.find(match.id).start_rematch!(user: users(:two)) })

      assert_equal [], results.grep(StandardError), "a rematch press raised: #{results.inspect}"
      assert_equal 1, results.map(&:id).uniq.length,
        "the two presses created different matches: #{results.map(&:id).inspect}"
      assert_equal before + 1, Match.count, "more than one rematch row was created"

      rematch = Match.find(results.first.id)
      assert_equal rematch, match.reload.rematch_match
      assert_equal "active", rematch.status, "the second press did not take the free seat"
      assert_equal users(:two), rematch.red_user, "the colours were not swapped"
      assert_equal users(:one), rematch.white_user
      assert_not_nil rematch.invite_token_used_at
      assert_not rematch.invite_open?, "the rematch link is still live after both joined"

      Move.delete_all
      Match.update_all(rematch_match_id: nil)
      Match.delete_all
    end
  end
end
