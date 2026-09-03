require "test_helper"

# The seat streams and who may listen on them.
#
# An online match broadcasts one rendering per audience, and the per-seat renderings carry
# controls and, after Play again, a rematch invite token. Two things have to hold for that to
# be private: a name the application signed subscribes and a name anybody could have written
# does not (Turbo's signature), and a seat's name only works for the player sitting in that
# seat (MatchStreamAuthorization). The second is what this file mostly pins: before it existed
# a websocket with no cookies at all, presenting the string it had read off the seat holder's
# page, was confirmed and received everything that seat received.
#
# The channel under test is Turbo::StreamsChannel itself, deliberately: the client names the
# channel its subscription runs through, so that is the name an attacker will use whatever the
# page says, and the guard has to be there rather than on a channel of ours.
#
# Nothing else depends on this: the connection identifies but authorises nothing, and every
# action that changes a match is authorised per request against the seat, not against a socket.
class TurboStreamsChannelTest < ActionCable::Channel::TestCase
  tests Turbo::StreamsChannel

  # A subclass of the channel is reachable by name in exactly the same way, so the rule has to
  # be inherited. Defined here rather than in the application because the application has no
  # use for one.
  class SubclassedStreamsChannel < Turbo::StreamsChannel; end

  # stream_name_from is private on the channel class, so the raw name is built the same way
  # the broadcaster does, through the public module the helper and the model both use.
  def stream_name_for(streamables)
    Turbo::StreamsChannel.send(:stream_name_from, streamables)
  end

  def signed(streamables)
    Turbo::StreamsChannel.signed_stream_name(streamables)
  end

  setup do
    @red = users(:one)
    @white = users(:two)
    @stranger = users(:three)
    @match = Match.open_online(creator: @red, colour: "red")
    @match.join!(@white)
  end

  # ---- the seat holder ------------------------------------------------------------------

  test "the player sitting in a seat subscribes to that seat's stream" do
    stub_connection current_user: @red, current_guest_key: nil

    subscribe signed_stream_name: signed(@match.stream_for("red"))

    assert_predicate subscription, :confirmed?
    assert_has_stream stream_name_for(@match.stream_for("red"))
  end

  test "the accepted seat subscription receives that seat's controls" do
    stub_connection current_user: @white, current_guest_key: nil
    subscribe signed_stream_name: signed(@match.stream_for("white"))
    assert_predicate subscription, :confirmed?

    messages = capture_broadcasts(stream_name_for(@match.stream_for("white"))) do
      @match.broadcast_state!
    end

    assert_equal 1, messages.length
    assert_includes messages.first, "Resign"
    assert_includes messages.first, "Offer a draw"
  end

  # ---- everybody else -------------------------------------------------------------------

  test "a connection with no identity is refused a seat stream" do
    stub_connection current_user: nil, current_guest_key: nil

    subscribe signed_stream_name: signed(@match.stream_for("red"))

    assert_predicate subscription, :rejected?
    assert_no_streams
  end

  test "a guest is refused a seat stream" do
    stub_connection current_user: nil, current_guest_key: "g" * 32

    subscribe signed_stream_name: signed(@match.stream_for("red"))

    assert_predicate subscription, :rejected?
    assert_no_streams
  end

  test "the other seat's player is refused this seat's stream" do
    stub_connection current_user: @white, current_guest_key: nil

    subscribe signed_stream_name: signed(@match.stream_for("red"))

    assert_predicate subscription, :rejected?
    assert_no_streams
  end

  test "a signed in stranger is refused a seat stream" do
    stub_connection current_user: @stranger, current_guest_key: nil

    subscribe signed_stream_name: signed(@match.stream_for("white"))

    assert_predicate subscription, :rejected?
    assert_no_streams
  end

  test "the rule is inherited by a subclass of the channel" do
    stub_connection current_user: nil, current_guest_key: nil

    subscribe_to SubclassedStreamsChannel, signed(@match.stream_for("red"))

    assert_predicate subscription, :rejected?
    assert_no_streams
  end

  # ---- the viewer stream ----------------------------------------------------------------

  test "the viewer stream is open to a connection with no identity" do
    stub_connection current_user: nil, current_guest_key: nil

    subscribe signed_stream_name: signed(@match.stream_for("viewer"))

    assert_predicate subscription, :confirmed?
    assert_has_stream stream_name_for(@match.stream_for("viewer"))
    assert_has_no_stream stream_name_for(@match.stream_for("red"))
    assert_has_no_stream stream_name_for(@match.stream_for("white"))
  end

  test "the viewer stream is open to a guest, a stranger and a seat holder alike" do
    [ [ nil, "g" * 32 ], [ @stranger, nil ], [ @red, nil ] ].each do |user, guest_key|
      stub_connection current_user: user, current_guest_key: guest_key

      subscribe signed_stream_name: signed(@match.stream_for("viewer"))

      assert_predicate subscription, :confirmed?
      assert_has_stream stream_name_for(@match.stream_for("viewer"))
    end
  end

  # ---- the signature --------------------------------------------------------------------

  test "the raw stream name, unsigned, is refused" do
    stub_connection current_user: @red, current_guest_key: nil

    subscribe signed_stream_name: stream_name_for(@match.stream_for("red"))

    assert_predicate subscription, :rejected?
  end

  test "a tampered signature is refused" do
    stub_connection current_user: @white, current_guest_key: nil

    subscribe signed_stream_name: "#{signed(@match.stream_for('white'))}x"

    assert_predicate subscription, :rejected?
  end

  test "an absent stream name is refused" do
    stub_connection current_user: @red, current_guest_key: nil

    subscribe

    assert_predicate subscription, :rejected?
  end

  test "a signed name that is not a match stream at all is refused" do
    stub_connection current_user: @red, current_guest_key: nil

    subscribe signed_stream_name: signed([ @red, "red" ])

    assert_predicate subscription, :rejected?
    assert_no_streams
  end

  test "the signature of one match's seat does not open another match's" do
    other = Match.open_online(creator: @red, colour: "red")
    stub_connection current_user: @red, current_guest_key: nil

    subscribe signed_stream_name: signed(other.stream_for("red"))

    assert_predicate subscription, :confirmed?
    assert_has_stream stream_name_for(other.stream_for("red"))
    assert_has_no_stream stream_name_for(@match.stream_for("red"))
  end

  private
    # subscribe/1 always uses the channel this case tests, so a subscription through another
    # channel class is built the way ActionCable::Channel::TestCase builds its own.
    def subscribe_to(channel_class, signed_stream_name)
      @subscription = channel_class.new(connection,
        ActionCable::Channel::TestCase::Behavior::CHANNEL_IDENTIFIER,
        { signed_stream_name: signed_stream_name }.with_indifferent_access)
      @subscription.singleton_class.include(ActionCable::Channel::ChannelStub)
      @subscription.subscribe_to_channel
      @subscription
    end
end
