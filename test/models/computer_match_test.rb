require "test_helper"

# A match against the computer, at the model layer: how the row is made, who sits where, what
# the reply writes, and what Undo takes back.
#
# The random source is seeded from config.x.ai_random_seed in the test environment (see
# config/environments/test.rb), so an Easy or a Medium reply is the same move every run and a
# test may name it. Hard deepens against the wall clock as well, so nothing here asserts a
# particular Hard move or a particular game length: only that the search reported a depth.
class ComputerMatchTest < ActiveSupport::TestCase
  GUEST = "computer-match-guest".freeze
  START = "rrrrrrrrrrrr--------wwwwwwwwwwww".freeze
  # White to move with exactly one legal move, the two-leg jump 24x15x8 over 19 and 11.
  FORCED_DOUBLE_JUMP = "--r-------r-------r----w--------".freeze
  # A Red king on 9 and a White king on 20: the shortest two-king shuttle the pinned test
  # seed drives into a threefold repetition, at ply 10 (tests/build/s5/probe_threefold_hunt.rb
  # searched all 992 two-king pairs and found 407 of them; this is one of the shortest).
  SHUTTLE = "--------R----------W------------".freeze
  # A Red king on 1 against two White kings, no capture available to either side: the
  # computer is a piece up and the forty-move counter still ends the game.
  QUIET_ENDGAME = "R--------------------------W--W-".freeze

  def computer_match(side: "red", level: "medium", guest_key: GUEST, user: nil)
    Match.open_ai(side: side, level: level, guest_key: guest_key, user: user)
  end

  # Plays a whole PDN move one leg at a time, the way a browser does, and lets the computer
  # answer exactly as MovesController does.
  def play(match, pdn)
    pdn.split(/[-x]/).map(&:to_i).each_cons(2) { |from, to| match.play_leg!(from, to) }
    match.play_computer_reply! if match.computer_to_move?
    match.reload
  end

  # The human plays whatever the engine offers first, leg by leg, and the computer answers:
  # a deterministic stand-in for a person clicking, for the tests that only care that a move
  # happened and not which one.
  def play_first_legal(match)
    move = match.game.legal_moves.first
    [ move.origin, *move.landings ].each_cons(2) { |from, to| match.play_leg!(from, to) }
    match.reload
    match.play_computer_reply! if match.computer_to_move?
    match.reload
  end

  def pdn_list(match) = match.moves.order(:ply).pluck(:pdn)

  # Puts a match into a constructed position, keeping it the first position of the match so
  # that the engine can rebuild the history from it.
  def set_board(match, board, side: "red", quiet_plies: 0)
    match.update!(position: board, start_position: board, side_to_move: side,
                  quiet_plies: quiet_plies)
    match.reload
  end

  # ---- creation (rubric 13, 33) --------------------------------------------------------

  test "a match as Red at each level starts from the opening with the human to move" do
    Draughts::AI::LEVELS.each do |level|
      match = computer_match(side: "red", level: level.to_s)

      assert_equal "ai", match.mode
      assert_equal "active", match.status
      assert_equal level.to_s, match.ai_level
      assert_equal START, match.position
      assert_equal START, match.start_position
      assert_equal "red", match.side_to_move
      assert_equal "red", match.human_side
      assert_equal "white", match.ai_side
      assert_equal 0, match.moves.count
      assert_not match.computer_to_move?, "the human moves first as Red"
    end
  end

  test "a match as White at each level has the computer play Red's first move" do
    Draughts::AI::LEVELS.each do |level|
      match = computer_match(side: "white", level: level.to_s)

      assert_equal "white", match.human_side
      assert_equal "red", match.ai_side
      assert match.computer_to_move?, "Red moves first and Red is the computer"

      choice = match.play_computer_reply!
      match.reload

      assert_equal 1, match.moves.count, "the computer's first move is exactly one row"
      row = match.moves.first
      assert_equal "red", row.side
      assert_equal 1, row.ply
      assert_equal choice.pdn, row.pdn
      assert_equal "white", match.side_to_move
      assert_not match.computer_to_move?
      assert_equal row.position_after, match.position
      assert_equal match.position, match.game.position.board_string
      assert_not_equal START, match.position

      # The stored position is the engine's own, replayed from the pinned opening.
      opening = Draughts::Position.start
      replayed = Draughts::Rules.apply(opening, Draughts::Rules.find_move(opening, row.pdn))
      assert_equal replayed.board_string, match.position
    end
  end

  test "the computer's seat holds no user and no guest key" do
    match = computer_match(side: "red", user: users(:one), guest_key: nil)

    assert_equal users(:one), match.red_user
    assert_nil match.white_user
    assert_nil match.white_guest_key
    assert_equal %w[red], match.seats_held_by(user: users(:one))
    assert_empty match.seats_held_by(guest_key: GUEST)
  end

  test "a guest holds only the colour it chose" do
    match = computer_match(side: "white")

    assert_equal %w[white], match.seats_held_by(guest_key: GUEST)
    assert_nil match.red_guest_key
  end

  test "open_ai refuses a colour, a level or an identity it cannot use" do
    assert_raises(ArgumentError) { Match.open_ai(side: "blue", level: "easy", guest_key: GUEST) }
    assert_raises(ArgumentError) { Match.open_ai(side: "red", level: "expert", guest_key: GUEST) }
    assert_raises(ArgumentError) { Match.open_ai(side: "red", level: "easy") }
  end

  test "a level belongs only to a computer match and a computer match needs one" do
    hotseat = Match.open_hotseat(guest_key: GUEST)
    hotseat.ai_level = "hard"

    assert_not hotseat.valid?
    assert_includes hotseat.errors[:ai_level], "belongs only to a match against the computer"

    match = computer_match
    match.ai_level = nil

    assert_not match.valid?
    assert_includes match.errors[:ai_level], "is required in a match against the computer"
  end

  # ---- names (rubric 32) ---------------------------------------------------------------

  test "the seats are named for the person and for the level" do
    assert_equal "Computer (Easy)", computer_match(level: "easy").seat_name("white")
    assert_equal "Computer (Medium)", computer_match(level: "medium").seat_name("white")
    assert_equal "Computer (Hard)", computer_match(level: "hard").seat_name("white")

    as_white = computer_match(side: "white", level: "hard")
    assert_equal "Computer (Hard)", as_white.seat_name("red")
    assert_equal "Guest", as_white.seat_name("white")

    signed_in = computer_match(side: "red", user: users(:one), guest_key: nil)
    assert_equal users(:one).display_name, signed_in.seat_name("red")
    assert_equal "Computer (Medium)", signed_in.seat_name("white")
  end

  test "the heading names the mode and the level" do
    assert_equal "Match against the computer (Hard)", computer_match(level: "hard").heading
  end

  # ---- the reply (rubric 13) -----------------------------------------------------------

  test "the reply row carries the search depth, nodes and elapsed time" do
    match = computer_match(level: "medium")
    play(match, "11-15")

    row = match.moves.order(:ply).last
    assert_equal "white", row.side
    assert_equal Draughts::AI::MEDIUM_DEPTH, row.ai_depth
    assert_operator row.ai_nodes, :>, 0
    assert_not_nil row.ai_elapsed_ms
    assert_equal row, match.last_computer_move

    human_row = match.moves.order(:ply).first
    assert_nil human_row.ai_depth, "a move a person played carries no search evidence"
    assert_nil human_row.ai_nodes
    assert_nil human_row.ai_elapsed_ms
  end

  test "a whole jump sequence the computer plays is one move row" do
    match = computer_match(side: "red", level: "medium")
    set_board(match, FORCED_DOUBLE_JUMP, side: "white")

    assert match.computer_to_move?
    choice = match.play_computer_reply!
    match.reload

    assert_equal "24x15x8", choice.pdn
    assert_equal 1, match.moves.count
    row = match.moves.first
    assert_equal "24x15x8", row.pdn
    assert_equal 24, row.origin
    assert_equal [ 15, 8 ], row.landings
    assert_equal [ 19, 11 ], row.captures
    assert_empty match.pending_path
  end

  test "the seeded random source makes Easy and Medium reply the same way twice" do
    %w[easy medium].each do |level|
      first = computer_match(level: level)
      second = computer_match(level: level)
      play(first, "11-15")
      play(second, "11-15")

      assert_equal pdn_list(first), pdn_list(second), "#{level} was not reproducible"
      assert_equal 2, first.moves.count
    end
  end

  test "a Hard reply reports a depth of at least the engine floor" do
    match = computer_match(level: "hard")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    play(match, "11-15")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    row = match.moves.order(:ply).last
    assert_equal "white", row.side
    assert_operator row.ai_depth, :>=, Draughts::AI::HARD_FLOOR
    assert_operator elapsed, :<, 3.0, "the reply took #{elapsed} s"
    assert_equal "red", match.side_to_move
  end

  test "the reply leaves the human to move and the position the engine computed" do
    match = computer_match(level: "medium")
    play(match, "11-15")

    assert_equal 2, match.moves.count
    assert_equal "red", match.side_to_move
    assert_not match.computer_to_move?
    assert_equal match.moves.order(:ply).last.position_after, match.position
    assert_equal 12, match.game.position.count(Draughts::Side::RED)
    assert_equal 12, match.game.position.count(Draughts::Side::WHITE)
  end

  test "there is no reply to ask for when it is the human's turn" do
    match = computer_match(level: "easy")

    assert_nil match.play_computer_reply!
    assert_equal 0, match.moves.count
  end

  test "a reply computed against a board that has moved on is discarded" do
    match = computer_match(level: "easy")
    match.play_leg!(11, 15)
    match.reload
    assert match.computer_to_move?

    # A second request for the same match, which plays the reply first.
    other = Match.find(match.id)
    assert other.play_computer_reply!
    assert_equal 2, other.reload.moves.count

    assert_nil match.play_computer_reply!, "the stale reply was applied a second time"
    assert_equal 2, match.reload.moves.count
  end

  # ---- undo (rubric 35) ----------------------------------------------------------------

  test "undo against the computer takes back two plies in one go" do
    match = computer_match(level: "medium")
    play(match, "11-15")
    assert_equal 2, match.moves.count
    assert_equal 2, match.undo_ply_count
    assert match.can_undo?

    match.undo_last_move!
    match.reload

    assert_equal 0, match.moves.count
    assert_equal START, match.position
    assert_equal "red", match.side_to_move
    assert_equal 0, match.quiet_plies
    assert_equal 0, match.game.plies
  end

  test "undo restores the position and the counters of the ply it went back to" do
    match = computer_match(level: "medium")
    play_first_legal(match)
    play_first_legal(match)
    before = { position: match.position, side: match.side_to_move, quiet: match.quiet_plies,
               moves: pdn_list(match) }
    play_first_legal(match)
    assert_equal 6, match.moves.count

    match.undo_last_move!
    match.reload

    assert_equal before[:position], match.position
    assert_equal before[:side], match.side_to_move
    assert_equal before[:quiet], match.quiet_plies
    assert_equal before[:moves], pdn_list(match)
    assert_equal before[:moves].length, match.game.plies
  end

  test "undo is refused when the only move is the computer's opening move as Red" do
    match = computer_match(side: "white", level: "easy")
    match.play_computer_reply!
    match.reload

    assert_equal 1, match.moves.count
    assert_equal 0, match.undo_ply_count
    assert_not match.can_undo?
    error = assert_raises(Draughts::IllegalMove) { match.undo_last_move! }
    assert_match(/opening move cannot be taken back/, error.message)
    assert_equal 1, match.reload.moves.count
  end

  test "a computer match with no moves at all is told there is nothing to undo" do
    # The zero of undo_ply_count means "the computer's opening move and nothing of yours".
    # A match with no rows is a different thing and gets the engine's own sentence, which is
    # what every other mode gets. Reachable by undoing the only pair of moves and asking again.
    match = computer_match(level: "easy")
    play(match, "11-15")
    match.undo_last_move!
    match.reload

    assert_equal 0, match.moves.count
    assert_equal 1, match.undo_ply_count
    assert_not match.can_undo?
    error = assert_raises(Draughts::IllegalMove) { match.undo_last_move! }
    assert_equal "there is no move to undo", error.message
  end

  test "one computer move from a constructed position is still an opening move" do
    # A row rewritten to a position with the computer to move, so its move is the first of the
    # game even though the game did not start from the pinned opening. There is no move of the
    # human's under it, so Undo is refused, and the sentence is about the opening move.
    match = computer_match(side: "red", level: "easy")
    set_board(match, FORCED_DOUBLE_JUMP, side: "white")
    match.play_computer_reply!
    match.reload

    assert_equal 1, match.moves.count
    assert_equal "white", match.moves.first.side
    assert_equal 0, match.undo_ply_count
    error = assert_raises(Draughts::IllegalMove) { match.undo_last_move! }
    assert_match(/opening move cannot be taken back/, error.message)
  end

  test "undo is refused while a jump sequence is pending" do
    match = computer_match(side: "white", level: "easy")
    set_board(match, FORCED_DOUBLE_JUMP, side: "white")
    match.play_leg!(24, 15)
    match.reload

    assert match.sequence_pending?
    assert_not match.can_undo?
    error = assert_raises(Draughts::IllegalMove) { match.undo_last_move! }
    assert_match(/jump sequence is pending/, error.message)
    assert_equal 0, match.reload.moves.count
  end

  test "undo is refused once the match has finished" do
    match = computer_match(level: "easy")
    play(match, "11-15")
    match.resign!("red")
    match.reload

    assert_not match.can_undo?
    error = assert_raises(Draughts::IllegalMove) { match.undo_last_move! }
    assert_match(/already finished/, error.message)
    assert_equal 2, match.reload.moves.count
  end

  test "undo takes back one ply when the computer never answered" do
    match = computer_match(level: "easy")
    match.play_leg!(11, 15)
    match.reload

    assert match.computer_to_move?, "the row rests on the computer's turn only in this case"
    assert_equal 1, match.undo_ply_count
    assert match.can_undo?

    match.undo_last_move!
    match.reload

    assert_equal 0, match.moves.count
    assert_equal "red", match.side_to_move
  end

  # ---- resignation and Play again (rubric 26, 37) --------------------------------------

  test "the human resigns their own seat and the computer's colour wins" do
    match = computer_match(side: "red", level: "hard")
    match.resign!("red")
    match.reload

    assert_equal "finished", match.status
    assert_equal "white_won", match.result
    assert_equal "resignation", match.reason
    assert_equal "Computer (Hard)", match.seat_name("white")
    assert_not match.can_undo?
    assert_not match.can_resign?
  end

  test "Play again carries the same mode, colour and level" do
    assert_equal({ mode: "ai", colour: "white", level: "hard" },
                 computer_match(side: "white", level: "hard").play_again_params)
    assert_equal({ mode: "ai", colour: "red", level: "easy" },
                 computer_match(side: "red", level: "easy").play_again_params)
    assert_equal({ mode: "hotseat" }, Match.open_hotseat(guest_key: GUEST).play_again_params)
  end

  # ---- draws with the computer ahead ---------------------------------------------------
  # The search sees positions, not histories, so it cannot steer away from a repetition or
  # from the forty-move count. Both rules still fire, and the wording is the hot-seat wording.

  test "a computer match draws by threefold repetition even though the computer is not losing" do
    match = computer_match(side: "red", level: "easy")
    set_board(match, SHUTTLE)

    20.times do
      break if match.reload.finished?

      move = match.game.legal_moves.first
      [ move.origin, *move.landings ].each_cons(2) { |from, to| match.play_leg!(from, to) }
      match.reload
      match.play_computer_reply! if match.computer_to_move?
    end
    match.reload

    assert_equal "finished", match.status
    assert_equal "draw", match.result
    assert_equal "threefold_repetition", match.reason
    assert_equal 10, match.moves.count
  end

  test "a computer match draws by the forty-move rule with the computer a piece up" do
    match = computer_match(side: "red", level: "easy")
    set_board(match, QUIET_ENDGAME, quiet_plies: 79)

    assert_equal 1, match.game.position.count(Draughts::Side::RED)
    assert_equal 2, match.game.position.count(Draughts::Side::WHITE)

    match.play_leg!(1, 5)
    match.reload

    assert_equal "finished", match.status
    assert_equal "draw", match.result
    assert_equal "forty_move_rule", match.reason
    assert_not match.computer_to_move?, "a finished match is never the computer's turn"
  end
end
