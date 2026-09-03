require "test_helper"

# Does a broadcast written by a different connection reach a subscriber in this process?
#
# The two-session system test proves that a broadcast arrives, but it runs with transactional
# tests on, where the pool is pinned: the Solid Cable listener reads the writer's row on the
# writer's own connection. The suite would therefore still pass if delivery only ever worked
# inside one process, which is exactly what an online game cannot rely on: the development
# server runs two Puma workers and production runs more (session-6 audit, finding L1).
#
# So this test writes the message the way another process would, through a sqlite3 handle of
# its own that knows nothing about Active Record's pool, and waits for the listener to pick it
# up. It fails if the transport is ever anything but the shared database.
class SolidCableDeliveryTest < ActiveSupport::TestCase
  # Transactional tests off, and that is the whole point. Measured with them on: the row was
  # written by the foreign handle and the listener never saw it in 10 s, because in WAL mode a
  # connection inside a transaction reads the snapshot it began with, and the listener runs on
  # the pinned connection that the test's transaction owns. That is precisely why the
  # two-session system test cannot prove cross-process delivery on its own.
  self.use_transactional_tests = false

  teardown { SolidCable::Message.where("channel LIKE ?", "cross-connection-probe-%").delete_all }

  def cable_database
    SolidCable::Record.connection_db_config.configuration_hash[:database]
  end

  # The channel_hash column Solid Cable indexes on: SHA256 of the name read as a signed 64-bit
  # big-endian integer, the same as SolidCable::Message.channel_hash_for.
  def channel_hash_for(channel)
    Digest::SHA256.digest(channel.to_s).unpack1("q>")
  end

  test "a message row written by a foreign connection reaches a subscriber here" do
    # Every environment runs Action Cable on Solid Cable (config/cable.yml), which is what makes
    # this test the right question to ask.
    assert_equal "solid_cable", Rails.application.config_for(:cable)[:adapter]

    # An adapter of this test's own, not ActionCable.server.pubsub: any test that includes
    # ActionCable::TestHelper (turbo-rails includes it into every ActiveSupport::TestCase once
    # Action Cable has been loaded) swaps the global one for the in-memory test adapter while it
    # runs, and whether that has happened before this test depends on the file order. This is
    # the real adapter with its own listener thread either way.
    adapter = ActionCable::SubscriptionAdapter::SolidCable.new(ActionCable.server)
    channel = "cross-connection-probe-#{SecureRandom.hex(6)}"
    received = Queue.new
    adapter.subscribe(channel, ->(message) { received << message })
    sleep 0.3 # let the listener register the channel before the row is written

    handle = SQLite3::Database.new(cable_database)
    begin
      # The table has no updated_at: Solid Cable's messages are written once and trimmed.
      handle.execute(<<~SQL, [ channel, channel_hash_for(channel), '{"probe":"foreign"}', Time.current.utc.iso8601(6) ])
        INSERT INTO solid_cable_messages (channel, channel_hash, payload, created_at)
        VALUES (?, ?, ?, ?)
      SQL
    ensure
      handle.close
    end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    message = nil
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < 10
      break if (message = received.pop(true) rescue nil)

      sleep 0.02
    end
    waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal '{"probe":"foreign"}', message,
      "nothing arrived in #{format('%.2f', waited)} s: delivery is not going through the database"
    assert_operator waited, :<, 2.0, "the poll took #{format('%.2f', waited)} s"
  ensure
    adapter&.shutdown
  end
end
