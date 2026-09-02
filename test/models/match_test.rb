require "test_helper"

# The match row and the transitions on it. Every legality question here is answered by the
# engine through Match#game, so these tests are about persistence: that what the engine
# decided is what the row ends up holding, and that a rebuilt game is the same game.
class MatchTest < ActiveSupport::TestCase
  GUEST = "guest-key-for-tests"
  START = "rrrrrrrrrrrr--------wwwwwwwwwwww".freeze

  def hotseat(guest_key: GUEST, user: nil)
    Match.open_hotseat(user: user, guest_key: guest_key)
  end

  # Plays a whole PDN move one leg at a time, the way a browser does.
  def play(match, pdn)
    squares = pdn.split(/[-x]/).map(&:to_i)
    squares.each_cons(2) { |from, to| match.play_leg!(from, to) }
    match
  end

  def play_all(match, *texts)
    texts.each { |text| play(match, text) }
    match
  end

  # ---- creation and the opening position (rubric 33, 36) -------------------------------

  test "a new hot-seat match starts from the pinned opening with Red to move" do
    match = hotseat

    assert_equal "hotseat", match.mode
    assert_equal "active", match.status
    assert_equal START, match.position
    assert_equal START, match.start_position
    assert_equal "red", match.side_to_move
    assert_equal 0, match.quiet_plies
    assert_empty match.pending_path
    assert_nil match.result
    assert_nil match.reason
    assert_equal 0, match.moves.count
  end

  test "the opening position holds 12 Red men on 1 to 12, 12 White men on 21 to 32, 13 to 20 empty" do
    position = hotseat.game.position

    assert_equal 12, position.count(Draughts::Side::RED)
    assert_equal 12, position.count(Draughts::Side::WHITE)
    (1..12).each { |square| assert_equal "r", position.at(square).char, "square #{square}" }
    (13..20).each { |square| assert_nil position.at(square), "square #{square}" }
    (21..32).each { |square| assert_equal "w", position.at(square).char, "square #{square}" }
  end

  test "the opening offers exactly the seven legal Red moves" do
    assert_equal %w[9-13 9-14 10-14 10-15 11-15 11-16 12-16],
      hotseat.game.legal_moves.map(&:pdn)
  end

  test "a hot-seat match needs an identity" do
    assert_raises(ArgumentError) { Match.open_hotseat }
  end

  # ---- validations --------------------------------------------------------------------

  test "the enums, the position format and the pinned result names are validated" do
    match = hotseat

    match.mode = "solitaire"
    assert_not match.valid?
    assert_includes match.errors[:mode].first, "not included"

    match.reload.position = "not a position"
    assert_not match.valid?

    match.reload.result = "red_wins"
    assert_not match.valid?

    match.reload.reason = "boredom"
    assert_not match.valid?

    match.reload.ai_level = "impossible"
    assert_not match.valid?

    match.reload
    match.result = "red_won"
    match.reason = "no_moves"
    assert match.valid?
  end

  test "the pinned result and reason names are exactly the engine's" do
    assert_equal %w[red_won white_won draw], Match::RESULTS
    assert_equal %w[no_pieces no_moves resignation agreement threefold_repetition forty_move_rule],
      Match::REASONS
  end

  test "a seat cannot be held by a user and a guest at once" do
    match = hotseat
    match.red_user = users(:one)

    assert_not match.valid?
    assert_includes match.errors[:base].join, "red seat"
  end

  test "an active match needs a player in both seats" do
    match = Match.new(mode: "hotseat", status: "active")

    assert_not match.valid?
    assert_equal 2, match.errors[:base].count { |m| m.include?("needs a player") }
  end

  test "a finished match must name its result and reason" do
    match = hotseat
    match.status = "finished"

    assert_not match.valid?
    assert match.errors[:result].any?
    assert match.errors[:reason].any?
  end

  # ---- seats and names ----------------------------------------------------------------

  test "the creating guest holds both seats and everybody else is a viewer" do
    match = hotseat

    assert_equal %w[red white], match.seats_held_by(guest_key: GUEST)
    assert_not match.viewer?(guest_key: GUEST)
    assert_empty match.seats_held_by(guest_key: "another-guest")
    assert match.viewer?(guest_key: "another-guest")
    assert match.viewer?(user: users(:one))
    assert match.viewer?
  end

  test "a signed-in creator holds both seats under their account and shows their name" do
    match = hotseat(guest_key: GUEST, user: users(:one))

    assert_nil match.red_guest_key
    assert_nil match.white_guest_key
    assert_equal %w[red white], match.seats_held_by(user: users(:one))
    assert_empty match.seats_held_by(guest_key: GUEST)
    assert_empty match.seats_held_by(user: users(:two))
    assert_equal "Ada", match.seat_name("red")
    assert_equal "Ada", match.seat_name("white")
  end

  test "a guest match names both players Guest" do
    match = hotseat

    assert_equal "Guest", match.seat_name("red")
    assert_equal "Guest", match.seat_name("white")
  end

  # ---- playing ------------------------------------------------------------------------

  test "a completed move writes one row and moves the stored position on" do
    match = hotseat
    leg = match.play_leg!(11, 15)

    assert leg.complete?
    assert_equal 1, match.moves.count

    row = match.moves.first
    assert_equal 1, row.ply
    assert_equal "red", row.side
    assert_equal "11-15", row.pdn
    assert_equal 11, row.origin
    assert_equal [ 15 ], row.landings
    assert_empty row.captures
    assert_not row.promoted
    assert_equal "rrrrrrrrrr-r--r-----wwwwwwwwwwww", row.position_after
    assert_equal row.position_after, match.position
    assert_equal "white", match.side_to_move
    assert_equal 0, match.quiet_plies
  end

  test "a whole jump sequence is one row with every landing and every captured square" do
    match = hotseat
    play_all(match, "12-16", "24-20", "8-12", "28-24", "16-19")

    first = match.play_leg!(24, 15)
    assert_not first.complete?
    assert_equal [ 24, 15 ], match.pending_path
    assert_equal 5, match.moves.count

    second = match.play_leg!(15, 8)
    assert second.complete?
    assert_equal 6, match.moves.count

    row = match.moves.last
    assert_equal "24x15x8", row.pdn
    assert_equal 24, row.origin
    assert_equal [ 15, 8 ], row.landings
    assert_equal [ 19, 11 ], row.captures
    assert_equal "red", match.side_to_move
    assert_empty match.pending_path
  end

  test "a leg that does not continue the pending sequence is refused and changes nothing" do
    match = hotseat
    play_all(match, "12-16", "24-20", "8-12", "28-24", "16-19")
    match.play_leg!(24, 15)
    before = match.attributes

    assert_raises(Draughts::IllegalMove) { match.play_leg!(23, 16) }
    assert_equal before, match.reload.attributes
    assert_equal [ 24, 15 ], match.pending_path
    assert_equal 5, match.moves.count
  end

  test "a quiet move is refused while a capture is available and changes nothing" do
    match = hotseat
    play_all(match, "11-15", "22-18")
    before = match.attributes

    assert_raises(Draughts::IllegalMove) { match.play_leg!(9, 13) }
    assert_equal before, match.reload.attributes
    assert_equal 2, match.moves.count
  end

  test "a move for the side not on turn is refused" do
    match = hotseat

    assert_raises(Draughts::IllegalMove) { match.play_leg!(22, 18) }
    assert_equal 0, match.moves.count
  end

  test "a square number that is not on the board is refused" do
    match = hotseat

    assert_raises(Draughts::InvalidPosition) { match.play_leg!(11, 33) }
    assert_raises(Draughts::InvalidPosition) { match.play_leg!("eleven", 15) }
    assert_raises(Draughts::InvalidPosition) { match.play_leg!(nil, nil) }
    assert_equal 0, match.moves.count
  end

  test "promotion during a jump ends the move and crowns the piece" do
    match = hotseat
    play_all(match, "11-16", "23-18", "9-14", "18x9", "6x13", "24-20", "2-6")

    assert_equal [ "20x11x2" ], match.game.legal_moves.map(&:pdn)
    match.play_leg!(20, 11)
    assert_equal [ 2 ], Draughts::Rules.continuations(match.game.position, match.pending_path)
    match.play_leg!(11, 2)

    row = match.moves.last
    assert_equal "20x11x2", row.pdn
    assert row.promoted
    assert_equal "W", match.game.position.at(2).char
    assert_equal "r", match.game.position.at(6).char, "the new king kept jumping"
    assert_equal "red", match.side_to_move
  end

  # ---- persistence: the row is the whole truth (rubric 14, 36) --------------------------

  test "a match reloaded from the database rebuilds the same game" do
    match = hotseat
    play_all(match, "11-15", "22-18", "15x22", "25x18", "12-16")

    fresh = Match.find(match.id)
    assert_equal match.game.position.key, fresh.game.position.key
    assert_equal match.game.moves.map(&:pdn), fresh.game.moves.map(&:pdn)
    assert_equal match.game.quiet_plies, fresh.game.quiet_plies
    assert_equal match.game.occurrence_count, fresh.game.occurrence_count
  end

  test "every stored position is exactly what the engine computes when the rows are replayed" do
    match = hotseat
    play_all(match, "11-15", "22-18", "15x22", "25x18", "12-16", "29-25", "16-20", "24-19")

    replay = Draughts::Game.new
    match.moves.order(:ply).each_with_index do |row, index|
      assert_equal index + 1, row.ply
      assert_equal replay.side_to_move.to_s, row.side
      replay.play(row.pdn)
      assert_equal replay.position.board_string, row.position_after,
        "row #{row.ply} (#{row.pdn}) stored a position the engine does not reproduce"
    end
    assert_equal replay.position.board_string, match.position
    assert_equal replay.side_to_move.to_s, match.side_to_move
    assert_equal replay.quiet_plies, match.quiet_plies
  end

  test "a pending path survives a reload and still locks the board to the jumping piece" do
    match = hotseat
    play_all(match, "12-16", "24-20", "8-12", "28-24", "16-19")
    match.play_leg!(24, 15)

    fresh = Match.find(match.id)
    assert fresh.sequence_pending?
    assert_equal 15, fresh.game.locked_square
    assert_equal({ 15 => [ 8 ] }, fresh.game.targets_by_square)
    assert_not fresh.can_undo?
    assert_not fresh.can_resign?
  end

  test "two requests racing on the same ply refuse the loser instead of raising" do
    match = hotseat
    first = Match.find(match.id)
    second = Match.find(match.id)

    first.play_leg!(11, 15)

    # The loser was composed against the opening position, but the transition reloads inside
    # its transaction, so the engine is asked about the board as it now stands and refuses.
    assert_raises(Draughts::IllegalMove) { second.play_leg!(11, 15) }
    assert_equal 1, match.reload.moves.count
    assert_equal "rrrrrrrrrr-r--r-----wwwwwwwwwwww", match.position
  end

  # ---- the draw rules through stored rows ----------------------------------------------

  test "a game restored from rows draws on the third occurrence of a position" do
    # F6: Red king on 4, White king on 29, 4-8 29-25 8-4 25-29 twice. The starting position
    # counts as its first occurrence, so the draw lands on ply 8.
    match = endgame({ "R" => [ 4 ], "W" => [ 29 ] })
    %w[4-8 29-25 8-4 25-29 4-8 29-25 8-4].each { |text| play(match, text) }

    assert_nil match.result
    assert_equal 2, match.game.occurrence_count(match.game.position)

    play(match, "25-29")

    assert_equal "finished", match.status
    assert_equal "draw", match.result
    assert_equal "threefold_repetition", match.reason
    assert_equal 8, match.moves.count
    assert_equal 3, Match.find(match.id).game.occurrence_count
  end

  test "a game restored from rows draws at exactly eighty quiet plies and not at seventy-nine" do
    match = endgame({ "R" => [ 4 ], "W" => [ 29 ] }, quiet_plies: 77)
    play(match, "4-8")
    assert_equal 78, match.quiet_plies
    assert_nil match.result

    play(match, "29-25")
    assert_equal 79, match.quiet_plies
    assert_nil match.result, "the forty-move rule fired one ply early"

    play(match, "8-11")
    assert_equal 80, match.quiet_plies
    assert_equal "draw", match.result
    assert_equal "forty_move_rule", match.reason
    assert_equal "finished", match.status
  end

  test "a man move resets the quiet-ply counter that a king move raised" do
    match = endgame({ "R" => [ 4 ], "w" => [ 30 ], "r" => [ 20 ] }, quiet_plies: 40)

    play(match, "4-8")
    assert_equal 41, match.quiet_plies

    play(match, "30-25")
    assert_equal 0, match.quiet_plies, "a White man move did not reset the counter"
  end

  # ---- terminal detection (rubric 21) --------------------------------------------------

  test "the side to move loses when it has no legal move" do
    # F5, reached by a real move so the row is written by the transition, not seeded: Red men
    # on 28, 27 and 19, White man on 32, Red to move. 19-23 boxes the White man in.
    match = endgame({ "w" => [ 32 ], "r" => [ 28, 27, 19 ] }, side: "red")
    assert_equal "active", match.status

    play(match, "19-23")

    assert_equal "finished", match.status
    assert_equal "red_won", match.result
    assert_equal "no_moves", match.reason
    assert_empty match.game.legal_moves
  end

  test "the side to move loses when its last piece is captured" do
    match = endgame({ "r" => [ 23 ], "w" => [ 27 ] }, side: "red")
    play(match, "23x32")

    assert_equal "finished", match.status
    assert_equal "red_won", match.result
    assert_equal "no_pieces", match.reason
    assert_equal 0, match.game.position.count(Draughts::Side::WHITE)
  end

  test "a finished match refuses every further action" do
    match = endgame({ "r" => [ 23 ], "w" => [ 27 ] }, side: "red")
    play(match, "23x32")
    before = match.reload.attributes

    assert_raises(Draughts::IllegalMove) { match.play_leg!(32, 27) }
    assert_raises(Draughts::IllegalMove) { match.undo_last_move! }
    assert_raises(Draughts::IllegalMove) { match.resign!("red") }
    assert_equal before, match.reload.attributes
    assert_not match.can_undo?
    assert_not match.can_resign?
  end

  # ---- undo ----------------------------------------------------------------------------

  test "undo takes back the last completed move and restores the side to move" do
    match = hotseat
    play_all(match, "11-15", "22-18")

    assert match.can_undo?
    undone = match.undo_last_move!

    assert_equal "22-18", undone.pdn
    assert_equal 1, match.moves.count
    assert_equal "rrrrrrrrrr-r--r-----wwwwwwwwwwww", match.position
    assert_equal "white", match.side_to_move
    assert_equal match.moves.last.position_after, match.position
  end

  test "undo restores the quiet-ply counter and the repetition counts" do
    match = endgame({ "R" => [ 4 ], "W" => [ 29 ] }, quiet_plies: 20)
    play_all(match, "4-8", "29-25", "8-4", "25-29")

    assert_equal 24, match.quiet_plies
    assert_equal 2, match.game.occurrence_count

    match.undo_last_move!

    assert_equal 23, match.quiet_plies
    assert_equal 1, match.game.occurrence_count
    assert_equal 1, Match.find(match.id).game.occurrence_count
  end

  test "undo is refused while a jump sequence is pending" do
    match = hotseat
    play_all(match, "12-16", "24-20", "8-12", "28-24", "16-19")
    match.play_leg!(24, 15)

    assert_not match.can_undo?
    assert_raises(Draughts::IllegalMove) { match.undo_last_move! }
    assert_equal 5, match.moves.count
  end

  test "undo is refused when there is nothing to undo" do
    match = hotseat

    assert_not match.can_undo?
    assert_raises(Draughts::IllegalMove) { match.undo_last_move! }
  end

  test "undo is refused in an online match even when the engine would allow it" do
    match = hotseat
    play(match, "11-15")
    match.update!(mode: "online")

    assert_not match.can_undo?
    assert_raises(Draughts::IllegalMove) { match.undo_last_move! }
    assert_equal 1, match.moves.count
  end

  # ---- resignation ---------------------------------------------------------------------

  test "resigning ends the match as a win for the other side" do
    match = hotseat
    play(match, "11-15")

    assert match.can_resign?
    match.resign!("white")

    assert_equal "finished", match.status
    assert_equal "red_won", match.result
    assert_equal "resignation", match.reason
    assert_equal 1, match.moves.count, "resigning must not touch the move list"
  end

  test "resigning is refused while a jump sequence is pending" do
    match = hotseat
    play_all(match, "12-16", "24-20", "8-12", "28-24", "16-19")
    match.play_leg!(24, 15)

    assert_not match.can_resign?
    assert_raises(Draughts::IllegalMove) { match.resign!("white") }
    assert_equal "active", match.status
  end

  # ---- M1: an active row at a terminal position ---------------------------------------

  test "a match cannot be saved active at a position the side to move has already lost" do
    # The session-4 audit's construction: fixture F5, White boxed in, White to move.
    match = Match.new(mode: "hotseat", status: "active", red_guest_key: GUEST,
                      white_guest_key: GUEST, start_position: boxed_in, position: boxed_in,
                      side_to_move: "white")

    assert_not match.valid?
    assert_includes match.errors[:status].join, "already lost"
    assert_raises(ActiveRecord::RecordInvalid) { match.save! }
  end

  test "a match cannot be saved active with no pieces for the side to move" do
    board = Draughts::Position::EMPTY_BOARD.dup
    [ 12, 16 ].each { |square| board[square - 1] = "r" }
    match = Match.new(mode: "hotseat", status: "active", red_guest_key: GUEST,
                      white_guest_key: GUEST, start_position: board, position: board,
                      side_to_move: "white")

    assert_not match.valid?
    assert_includes match.errors[:status].join, "already lost"
  end

  test "a row that slipped through as active at a terminal position heals when it is loaded" do
    match = Match.new(mode: "hotseat", status: "active", red_guest_key: GUEST,
                      white_guest_key: GUEST, start_position: boxed_in, position: boxed_in,
                      side_to_move: "white")
    match.save!(validate: false)

    assert_equal "active", match.reload.status

    game = match.game

    assert game.finished?
    assert_equal "finished", match.status, "the row was left contradicting the engine"
    assert_equal "red_won", match.result
    assert_equal "no_moves", match.reason
    assert_equal [ "finished", "red_won", "no_moves" ],
      Match.find(match.id).then { |m| [ m.status, m.result, m.reason ] }
    assert_not match.can_undo?
    assert_not match.can_resign?
  end

  # ---- M2: the heading and Play again come from the row --------------------------------

  test "the heading and the play again settings are derived from the mode" do
    match = hotseat

    assert_equal "Hot-seat match", match.heading
    assert_equal({ mode: "hotseat" }, match.play_again_params)

    match.mode = "online"
    assert_equal "Online match", match.heading
    assert_equal({ mode: "online" }, match.play_again_params)

    match.mode = "ai"
    match.ai_level = "hard"
    assert_equal "Match against the computer (Hard)", match.heading
    assert_equal({ mode: "ai", ai_level: "hard" }, match.play_again_params)
  end

  # ---- H2 and L3: one sentence per state, and it is truthful ---------------------------

  test "a waiting match is never told it has finished" do
    match = hotseat
    match.update_columns(status: "waiting")

    assert_equal "this match has not started yet", match.inactive_reason
    assert_equal "this match has not started yet", match.resignation_refusal
    assert_equal "this match has not started yet",
      assert_raises(Draughts::IllegalMove) { match.play_leg!(11, 15) }.message
    assert_equal "this match has not started yet",
      assert_raises(Draughts::IllegalMove) { match.resign!("red") }.message
    assert_equal "this match has not started yet",
      assert_raises(Draughts::IllegalMove) { match.undo_last_move! }.message
    assert_not match.can_undo?
    assert_not match.can_resign?
  end

  test "a finished match says so, and a pending jump says so" do
    match = hotseat
    play(match, "11-15")
    match.resign!("white")

    assert_equal "this match has already finished", match.inactive_reason
    assert_equal "this match has already finished", match.resignation_refusal

    other = hotseat
    play_all(other, "12-16", "24-20", "8-12", "28-24", "16-19")
    other.play_leg!(24, 15)

    assert_nil other.inactive_reason
    assert_equal "a jump sequence is pending on square 15", other.resignation_refusal
  end

  # ---- L1: only one or two decimal digits name a square --------------------------------

  test "a square parameter must be one or two plain decimal digits" do
    match = hotseat

    [ "0x0b", "013", "0b1011", "1_1", "+11", " 11 ", "11
", "11 ", "11.0", "0011", "-11",
      "", " ", "0", "33", "99", "eleven", "1e1", nil, [ "11" ], { "a" => "11" } ].each do |value|
      assert_raises(Draughts::InvalidPosition, "#{value.inspect} was accepted as a square") do
        Match.square_number(value)
      end
    end

    (1..32).each { |square| assert_equal square, Match.square_number(square.to_s) }
    assert_equal 11, Match.square_number(11)
  end

  test "a non-decimal spelling of a square number never reaches the engine" do
    match = hotseat

    assert_raises(Draughts::InvalidPosition) { match.play_leg!("0x0b", 15) }
    assert_raises(Draughts::InvalidPosition) { match.play_leg!("013", "15") }
    assert_raises(Draughts::InvalidPosition) { match.play_leg!(" 11 ", 15) }
    assert_raises(Draughts::InvalidPosition) { match.play_leg!("+11", 15) }
    assert_equal 0, match.reload.moves.count
  end

  private
    # Fixture F5: a White man on 32 boxed in by Red men on 28, 27 and 23, so White to move has
    # no legal move at all.
    def boxed_in
      board = Draughts::Position::EMPTY_BOARD.dup
      [ 28, 27, 23 ].each { |square| board[square - 1] = "r" }
      board[31] = "w"
      board
    end

    # A match seeded at a constructed position, for the endgames the draw and terminal rules
    # need. start_position is what makes this exact: Draughts::Game.restore counts occurrences
    # from the match's own start, not from the standard opening.
    def endgame(pieces, side: "red", quiet_plies: 0)
      board = Draughts::Position::EMPTY_BOARD.dup
      pieces.each { |char, squares| squares.each { |square| board[square - 1] = char } }

      Match.create!(mode: "hotseat", status: "active",
                    red_guest_key: GUEST, white_guest_key: GUEST,
                    start_position: board, position: board,
                    side_to_move: side, quiet_plies: quiet_plies)
    end
end
