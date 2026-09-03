require "test_helper"
# turbo-rails includes this into ActiveSupport::TestCase only once Action Cable itself has
# been loaded, which is lazy, so the file is required here rather than relied on.
require "turbo/broadcastable/test_helper"

# What a match pushes over Action Cable after an action, and to whom.
#
# The live layer is the point of the online mode, and the thing that can quietly go wrong in
# it is not "nothing arrives" (a system test catches that) but "the wrong thing arrives at the
# wrong person": the opponent's controls on a shared stream, or a rematch invite token on the
# stream every viewer of the match is listening to. That is what this file pins.
#
# Turbo::Broadcastable::TestHelper swaps the in-memory Action Cable test adapter in for the
# duration of each test, so these assertions are about what was published and to which stream,
# not about delivery. Delivery over the real Solid Cable adapter is measured by the two-session
# system test in test/system/online_test.rb.
class MatchBroadcastsTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper
  include Rails.application.routes.url_helpers

  FRAGMENT_IDS = [ Match::BOARD_ID, Match::STATUS_ID, Match::INVITE_ID,
                   Match::MOVES_ID, Match::CONTROLS_ID ].freeze

  def online(colour: "red")
    Match.open_online(creator: users(:one), colour: colour).tap { |match| match.join!(users(:two)) }
  end

  def hotseat
    Match.open_hotseat(guest_key: "g" * 32)
  end

  # Runs one action and returns what each of the three audiences received from that action
  # alone, as { audience => [turbo-stream elements] }. The captures nest because each one
  # remembers its own stream's messages before the block and reports the difference after.
  def broadcasts_from(match)
    captured = {}
    captured["red"] = capture_turbo_stream_broadcasts(match.stream_for("red")) do
      captured["white"] = capture_turbo_stream_broadcasts(match.stream_for("white")) do
        captured["viewer"] = capture_turbo_stream_broadcasts(match.stream_for("viewer")) do
          yield
        end
      end
    end
    captured
  end

  def text_of(elements)
    elements.map(&:to_html).join("\n")
  end

  test "a completed move reaches all three audiences of an online match" do
    match = online

    sent = broadcasts_from(match) { match.play_leg!(11, 15) }

    Match::SIDES.+([ "viewer" ]).each do |audience|
      elements = sent.fetch(audience)
      assert_equal FRAGMENT_IDS, elements.map { |element| element["target"] },
        "the #{audience} audience did not get all five fragments"
      assert_equal [ "replace" ], elements.map { |element| element["action"] }.uniq
    end
  end

  test "one action is one message per audience, not one per fragment" do
    match = online

    assert_broadcasts stream_name_from(match.stream_for("red")), 1 do
      assert_broadcasts stream_name_from(match.stream_for("white")), 1 do
        assert_broadcasts stream_name_from(match.stream_for("viewer")), 1 do
          match.play_leg!(11, 15)
        end
      end
    end
  end

  test "a hot-seat match broadcasts to viewers only" do
    match = hotseat

    sent = broadcasts_from(match) { match.play_leg!(11, 15) }

    assert_equal 5, sent["viewer"].length
    assert_equal 0, sent["red"].length, "a hot-seat match broadcast to a seat stream"
    assert_equal 0, sent["white"].length
  end

  test "the viewer stream carries no controls and no playable board" do
    match = online

    viewer = text_of(broadcasts_from(match) { match.play_leg!(11, 15) }["viewer"])

    assert_includes viewer, "You are viewing this match"
    assert_not_includes viewer, "Resign"
    assert_not_includes viewer, "Offer a draw"
    assert_not_includes viewer, "data-legal-targets"
    assert_not_includes viewer, match_moves_path(match)
  end

  test "each seat stream carries that seat's controls and only that seat's" do
    match = online
    match.play_leg!(11, 15)

    sent = broadcasts_from(match) { match.offer_draw!("red") }
    white = text_of(sent["white"])
    red = text_of(sent["red"])

    # White is to move, so White's board is the live one and Red's is not.
    assert_includes white, "data-legal-targets"
    assert_not_includes red, "data-legal-targets"
    # The offer is answered by White alone; Red is told it is waiting.
    assert_includes white, match_draw_accept_path(match)
    assert_includes white, match_draw_decline_path(match)
    assert_not_includes red, match_draw_accept_path(match)
    assert_includes red, "You have offered a draw"
    assert_includes red, "Resign"
    assert_includes white, "Resign"
    # And the offer itself is on the neutral status line everyone reads.
    assert_includes text_of(sent["viewer"]), "has offered a draw"
  end

  test "joining broadcasts the active board and empties the creator's invite panel" do
    match = Match.open_online(creator: users(:one), colour: "red")
    token = match.invite_token

    sent = broadcasts_from(match) { match.join!(users(:two)) }

    assert_includes text_of(sent["red"]), "Your move"
    assert_not_includes text_of(sent["red"]), token,
      "the invite panel still carried the token after the join"
    assert_not_includes text_of(sent["viewer"]), token
    assert_includes text_of(sent["viewer"]), "Grace"
  end

  test "cancelling broadcasts the cancelled board to everyone" do
    match = Match.open_online(creator: users(:one), colour: "red")

    sent = broadcasts_from(match) { match.cancel! }

    assert_includes text_of(sent["viewer"]), "This match was cancelled"
    assert_not_includes text_of(sent["viewer"]), match.invite_token
  end

  test "a resignation and a draw answer both broadcast the result" do
    match = online
    sent = broadcasts_from(match) { match.resign!("red") }
    assert_includes text_of(sent["white"]), "White wins by resignation"

    agreed = online
    agreed.offer_draw!("red")
    answered = broadcasts_from(agreed) { agreed.answer_draw!("white", accept: true) }
    assert_includes text_of(answered["viewer"]), "Draw by agreement"
  end

  test "the rematch link reaches the opponent's seat and never the viewer stream" do
    match = online
    match.resign!("red")

    sent = broadcasts_from(match) { match.start_rematch!(user: users(:one)) }
    rematch = match.reload.rematch_match

    assert_includes text_of(sent["white"]), join_path(rematch.invite_token)
    assert_includes text_of(sent["white"]), "has started a rematch"
    assert_not_includes text_of(sent["viewer"]), rematch.invite_token
    assert_not_includes text_of(sent["red"]), join_path(rematch.invite_token)
    assert_includes text_of(sent["red"]), "You have started a rematch"
  end

  test "the computer's reply broadcasts too" do
    match = Match.open_ai(side: "red", level: "easy", guest_key: "g" * 32)

    sent = broadcasts_from(match) do
      match.play_leg!(11, 15)
      match.play_computer_reply!
    end

    assert_equal 10, sent["viewer"].length, "the human's move and the computer's reply are two messages"
    assert_equal 2, match.reload.moves.count
  end

  # ---- who listens ---------------------------------------------------------------------

  test "a page subscribes only when somebody else can change the match" do
    match = online

    assert_equal "red", match.live_audience([ "red" ])
    assert_equal "white", match.live_audience([ "white" ])
    assert_equal "viewer", match.live_audience([])

    local = hotseat
    assert_nil local.live_audience(%w[ red white ]), "the hot-seat browser must not hear its own echo"
    assert_equal "viewer", local.live_audience([])

    computer = Match.open_ai(side: "red", level: "easy", guest_key: "g" * 32)
    assert_nil computer.live_audience([ "red" ]), "the human is the only actor in a computer match"
    assert_equal "viewer", computer.live_audience([])
  end

  # A signed stream name is a bearer token: whoever holds it receives that audience's fragments
  # for as long as the socket lives. Naming a seat stream after the seat's user means a name is
  # dead the moment somebody else holds the seat, which is the defence in depth behind the join
  # rule (session-6 audit, findings M2 and C1).
  test "a seat stream is named after the user sitting in it" do
    match = online

    white_before = stream_name_from(match.stream_for("white"))
    viewer_before = stream_name_from(match.stream_for("viewer"))
    assert_includes white_before, users(:two).to_gid_param
    assert_not_includes viewer_before, users(:two).to_gid_param

    # A seat changing hands is not reachable through any transition; written directly here so
    # the naming rule itself is what is tested.
    match.update_columns(white_user_id: users(:three).id)
    match.reload

    assert_not_equal white_before, stream_name_from(match.stream_for("white")),
      "the old holder's stream name still names this seat"
    assert_includes stream_name_from(match.stream_for("white")), users(:three).to_gid_param
    assert_equal viewer_before, stream_name_from(match.stream_for("viewer")),
      "the viewer stream must not move when a seat does"
  end

  test "a broadcast goes to the name the seat holder's page subscribed to" do
    match = online
    page_name = stream_name_from(match.stream_for("white"))

    sent = broadcasts_from(match) { match.play_leg!(11, 15) }

    assert_equal 5, sent["white"].length
    assert_equal page_name, stream_name_from(match.stream_for("white"))
    assert_operator broadcasts(page_name).length, :>=, 1
  end

  # db/seeds.rb replays a whole game through the public move path with nobody listening.
  test "silence_broadcasts stops the broadcasts inside the block and only inside it" do
    match = online

    silenced = broadcasts_from(match) do
      Match.silence_broadcasts { match.play_leg!(11, 15) }
    end
    assert_equal [ 0, 0, 0 ], silenced.values.map(&:length), "nothing may be published"
    assert_equal [ "11-15" ], match.reload.moves.map(&:pdn), "but the move was still played"
    assert_not Match.broadcasts_silenced?, "the flag is put back"

    after = broadcasts_from(match) { match.play_leg!(22, 18) }
    assert_equal 5, after.fetch("viewer").length, "broadcasting resumes after the block"
  end

  test "silence_broadcasts puts the flag back even when the block raises" do
    assert_raises(Draughts::IllegalMove) do
      Match.silence_broadcasts { online.play_leg!(11, 12) }
    end

    assert_not Match.broadcasts_silenced?
  end

  test "the stream name is one string per match and audience" do
    match = online
    other = online

    names = (Match::SIDES + [ "viewer" ]).map { |audience| stream_name_from(match.stream_for(audience)) }

    assert_equal 3, names.uniq.length
    names.each { |name| assert_includes name, match.to_gid_param }
    assert_not_equal stream_name_from(match.stream_for("red")), stream_name_from(other.stream_for("red"))
  end
end
