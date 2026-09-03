require "test_helper"

# The seat streams are only as private as their names.
#
# An online match broadcasts one rendering per audience, and the per-seat renderings carry
# controls and, after Play again, a rematch invite token. The page hands a browser the signed
# name of the stream it is entitled to, and this pins the two things that makes safe: a name
# the application signed subscribes, and a name anybody could have written does not.
#
# Nothing else depends on it: the connection identifies but authorises nothing, and every
# action that changes a match is authorised per request against the seat, not against a socket.
class TurboStreamsChannelTest < ActionCable::Channel::TestCase
  tests Turbo::StreamsChannel

  # stream_name_from is private on the channel class, so the raw name is built the same way
  # the broadcaster does, through the public module the helper and the model both use.
  def stream_name_for(streamables)
    Turbo::StreamsChannel.send(:stream_name_from, streamables)
  end

  setup do
    stub_connection
    @match = Match.open_online(creator: users(:one), colour: "red")
    @match.join!(users(:two))
  end

  test "a stream name the application signed subscribes to that stream" do
    subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name(@match.stream_for("red"))

    assert_predicate subscription, :confirmed?
    assert_has_stream stream_name_for(@match.stream_for("red"))
  end

  test "the raw stream name, unsigned, is refused" do
    subscribe signed_stream_name: stream_name_for(@match.stream_for("red"))

    assert_predicate subscription, :rejected?
  end

  test "a tampered signature is refused" do
    signed = Turbo::StreamsChannel.signed_stream_name(@match.stream_for("white"))

    subscribe signed_stream_name: "#{signed}x"

    assert_predicate subscription, :rejected?
  end

  test "the signature of one match's seat does not open another match's" do
    other = Match.open_online(creator: users(:three), colour: "red")

    subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name(other.stream_for("red"))

    assert_predicate subscription, :confirmed?
    assert_has_no_stream stream_name_for(@match.stream_for("red"))
  end

  test "the viewer stream is a different stream from either seat" do
    subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name(@match.stream_for("viewer"))

    assert_predicate subscription, :confirmed?
    assert_has_stream stream_name_for(@match.stream_for("viewer"))
    assert_has_no_stream stream_name_for(@match.stream_for("red"))
    assert_has_no_stream stream_name_for(@match.stream_for("white"))
  end
end
