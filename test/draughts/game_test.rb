# frozen_string_literal: true

require "minitest/autorun"
require "draughts"

# A game in progress: history, the two draw counters, the pending jump path, undo, resign,
# and rebuilding a game from what the Rails application stores.
class DraughtsGameTest < Minitest::Test
  include Draughts

  def test_a_new_game_is_the_opening_position_with_red_to_move
    game = Game.new

    assert_equal Position.start, game.position
    assert_equal Side::RED, game.side_to_move
    assert_equal 0, game.plies
    assert_equal 0, game.quiet_plies
    assert_empty game.moves
    assert_nil game.result
    assert_nil game.reason
    assert_nil game.last_move
    refute game.finished?
    refute game.pending?
    assert_nil game.locked_square
    assert_equal 1, game.occurrence_count, "the starting position counts as its first occurrence"
    assert_equal 7, game.legal_moves.length
  end

  def test_playing_a_move_updates_the_position_history_and_turn
    game = Game.new
    move = game.play("11-15")

    assert_equal "11-15", move.pdn
    assert_equal Side::WHITE, game.side_to_move
    assert_equal 1, game.plies
    assert_equal [ "11-15" ], game.moves.map(&:pdn)
    assert_equal move, game.last_move
    assert_nil game.position.at(11)
    assert_equal Piece::RED_MAN, game.position.at(15)
    assert_equal 1, game.occurrence_count
  end

  def test_play_accepts_pdn_text_or_a_move_and_refuses_anything_illegal
    game = Game.new

    assert_equal "11-15", game.play(Rules.move!(Position.start, "11-15")).pdn
    assert_raises(Draughts::IllegalMove) { game.play("11-15") }
    assert_raises(Draughts::IllegalMove, "Red cannot move twice") { game.play("9-13") }
    assert_raises(Draughts::IllegalMove) { game.play("22-13") }
    assert_raises(Draughts::IllegalMove) { game.play("nonsense") }
    assert_equal "22-17", game.play("22-17").pdn
  end

  def test_a_finished_game_refuses_every_action
    game = Game.new(Position.build({ 4 => "r", 8 => "w" }, Side::RED))
    game.play("4x11")

    assert game.finished?
    assert_equal :red_won, game.result
    assert_empty game.legal_moves
    assert_empty game.legal_targets(11)
    assert_raises(Draughts::IllegalMove) { game.play("11-15") }
    assert_raises(Draughts::IllegalMove) { game.play_leg(11, 15) }
    assert_raises(Draughts::IllegalMove) { game.resign(Side::RED) }
    assert_raises(Draughts::IllegalMove) { game.agree_draw }
    refute game.can_undo?
  end

  # -- terminal detection, in the order no pieces, no moves, threefold, forty-move -----

  def test_losing_by_having_no_pieces_left
    game = Game.new(Position.build({ 4 => "r", 8 => "w" }, Side::RED))
    game.play("4x11")

    assert_equal :red_won, game.result
    assert_equal :no_pieces, game.reason
    assert_equal Side::RED, game.winner
    assert_equal Side::WHITE, game.side_to_move, "the side that cannot answer is still to move"
  end

  def test_losing_by_having_no_legal_move
    game = Game.new(Position.build({ 11 => "r", 4 => "w" }, Side::RED))
    game.play("11-16")

    assert_equal 1, game.position.count(Side::WHITE)
    assert_equal :red_won, game.result
    assert_equal :no_moves, game.reason
  end

  # A constructed position where the side to move still has pieces and the opponent has none
  # is not terminal for one more ply, because the rule is "the side TO MOVE loses when it has
  # no pieces". The reference model does exactly the same (checkers-model.py _check_terminal
  # tests pos.side), and real play cannot reach it: taking the last piece hands the turn to
  # the side that now has none. Pinned so a later phase does not read it as a bug.
  def test_the_loss_belongs_to_the_side_to_move_not_to_the_empty_side
    game = Game.new(Position.build({ 4 => "r" }, Side::RED))

    assert_nil game.result, "Red is to move and Red has a piece"
    assert_equal 0, game.position.count(Side::WHITE)

    game.play("4-8")
    assert_equal :red_won, game.result
    assert_equal :no_pieces, game.reason

    mirrored = Game.new(Position.build({ 4 => "r" }, Side::WHITE))
    assert_equal :red_won, mirrored.result, "White to move with no pieces loses at once"
    assert_equal :no_pieces, mirrored.reason
  end

  def test_no_pieces_is_reported_before_no_moves
    # A side with no pieces also has no moves; the pinned order names the pieces first.
    game = Game.new(Position.build({ 4 => "r", 8 => "w" }, Side::RED))
    game.play("4x11")

    assert_equal :no_pieces, game.reason
  end

  def test_no_moves_is_reported_before_threefold_repetition
    # F5's position, restored as if it had already occurred twice before.
    position = Position.build({ 32 => "w", 28 => "r", 27 => "r", 23 => "r" }, Side::WHITE)
    game = Game.restore(position: position, positions: [ position.key ] * 3)

    assert_equal 3, game.occurrence_count
    assert_equal :red_won, game.result
    assert_equal :no_moves, game.reason
  end

  def test_threefold_repetition_is_reported_before_the_forty_move_rule
    game = Game.new(Position.build({ 4 => "R", 29 => "W" }, Side::RED))
    game.quiet_plies = 72
    [ "4-8", "29-25", "8-4", "25-29" ].cycle.first(8).each { |text| game.play(text) }

    assert_equal 80, game.quiet_plies, "both rules fire on this ply"
    assert_equal :draw, game.result
    assert_equal :threefold_repetition, game.reason
  end

  def test_the_forty_move_rule_needs_eighty_plies_not_seventy_nine
    game = Game.new(Position.build({ 4 => "R", 29 => "W" }, Side::RED))
    game.quiet_plies = 78

    game.play("4-8")
    assert_equal 79, game.quiet_plies
    assert_nil game.result, "79 quiet plies is not a draw"

    game.play("29-25")
    assert_equal 80, game.quiet_plies
    assert_equal :draw, game.result
    assert_equal :forty_move_rule, game.reason
  end

  def test_the_quiet_ply_counter_can_be_set_and_is_validated
    game = Game.new
    game.quiet_plies = 5

    assert_equal 5, game.quiet_plies
    assert_raises(Draughts::InvalidPosition) { game.quiet_plies = -1 }
    assert_raises(TypeError, ArgumentError) { game.quiet_plies = "many" }
  end

  def test_resignation_and_an_agreed_draw
    resigned = Game.new
    resigned.play("11-15")
    resigned.resign(Side::WHITE)

    assert_equal :red_won, resigned.result
    assert_equal :resignation, resigned.reason
    assert_equal Side::RED, resigned.winner

    agreed = Game.new
    agreed.agree_draw
    assert_equal :draw, agreed.result
    assert_equal :agreement, agreed.reason
    assert_nil agreed.winner
    assert agreed.drawn?
  end

  def test_the_result_and_reason_names_are_the_pinned_ones
    assert_equal [ :red_won, :white_won, :draw ], Game::RESULTS
    assert_equal [ :no_pieces, :no_moves, :resignation, :agreement,
                  :threefold_repetition, :forty_move_rule ], Game::REASONS
  end

  # -- leg by leg ---------------------------------------------------------------------

  def test_a_leg_that_finishes_a_quiet_move_records_it_at_once
    game = Game.new
    result = game.play_leg(11, 15)

    assert result.complete?
    assert_equal "11-15", result.move.pdn
    assert_equal 1, game.plies
    refute game.pending?
  end

  def test_a_pending_sequence_locks_the_board_to_the_jumping_piece
    game = Game.new(Position.build({ 4 => "r", 8 => "w", 15 => "w", 29 => "W" }, Side::RED))
    game.play_leg(4, 11)

    assert game.pending?
    assert_equal [ 4, 11 ], game.pending_path
    assert_equal 11, game.locked_square
    assert_equal 0, game.plies, "nothing is recorded until the sequence ends"
    assert_equal [ 18 ], game.legal_targets(11)
    assert_equal [], game.legal_targets(4)
    assert_equal [ "4x11x18" ], game.legal_moves.map(&:pdn)
    refute game.can_undo?
    assert_raises(Draughts::IllegalMove) { game.play_leg(29, 25) }
    assert_raises(Draughts::IllegalMove) { game.play("4x11x18") }

    game.play_leg(11, 18)
    assert_equal 1, game.plies
    assert_equal "4x11x18", game.last_move.pdn
    refute game.pending?
  end

  def test_targets_by_square_follows_the_pending_lock_and_the_result
    game = Game.new

    assert_equal({ 9 => [ 13, 14 ], 10 => [ 14, 15 ], 11 => [ 15, 16 ], 12 => [ 16 ] },
                 game.targets_by_square)

    game = Game.new(Position.build({ 4 => "r", 8 => "w", 15 => "w", 29 => "W" }, Side::RED))
    assert_equal({ 4 => [ 11 ] }, game.targets_by_square)

    game.play_leg(4, 11)
    assert_equal({ 11 => [ 18 ] }, game.targets_by_square, "only the locked piece is offered")

    game.play_leg(11, 18)
    assert_equal game.targets_by_square.keys, [ 29 ], "White is to move now"

    finished = Game.new(Position.build({ 4 => "r", 8 => "w" }, Side::RED))
    finished.play("4x11")
    assert_empty finished.targets_by_square
  end

  def test_the_board_shown_during_a_pending_sequence
    game = Game.new(Position.build({ 4 => "r", 8 => "w", 15 => "w", 29 => "W" }, Side::RED))
    assert_equal game.position, game.display_position

    game.play_leg(4, 11)
    shown = game.display_position

    assert_equal Piece::RED_MAN, shown.at(11)
    assert_nil shown.at(4)
    assert_nil shown.at(8), "the piece taken so far is shown gone"
    assert_equal Piece::WHITE_MAN, shown.at(15)
    assert_equal Side::RED, shown.side_to_move
    assert_equal Piece::WHITE_MAN, game.position.at(8), "the stored position is untouched"
  end

  def test_a_leg_from_the_wrong_piece_or_the_wrong_side_is_refused
    game = Game.new

    assert_raises(Draughts::IllegalMove) { game.play_leg(22, 18) }
    assert_raises(Draughts::IllegalMove) { game.play_leg(13, 17) }
    assert_raises(Draughts::IllegalMove) { game.play_leg(11, 16) && game.play_leg(9, 13) }
    assert_raises(Draughts::InvalidPosition) { game.play_leg(33, 1) }
  end

  # -- undo ----------------------------------------------------------------------------

  def test_undo_restores_the_position_side_counters_and_occurrences
    game = Game.new(Position.build({ 4 => "R", 29 => "W", 13 => "r" }, Side::RED))
    before_key = game.position.key
    game.quiet_plies = 3
    game.play("4-8")

    assert_equal 4, game.quiet_plies
    undone = game.undo

    assert_equal "4-8", undone.pdn
    assert_equal before_key, game.position.key
    assert_equal Side::RED, game.side_to_move
    assert_equal 3, game.quiet_plies, "the counter goes back to what it was"
    assert_equal 0, game.plies
    assert_empty game.moves
    assert_equal 1, game.occurrence_count
    assert_raises(Draughts::IllegalMove) { game.undo }
  end

  # TASK-BRIEF.md 1.6: Undo is "unavailable once the match has finished". The engine refuses
  # it outright rather than leaving that to the caller, for a draw and for a resignation.
  def test_undo_is_refused_once_the_game_has_finished
    drawn = Game.new(Position.build({ 4 => "R", 29 => "W" }, Side::RED))
    [ "4-8", "29-25", "8-4", "25-29" ].cycle.first(8).each { |text| drawn.play(text) }

    assert_equal :threefold_repetition, drawn.reason
    refute drawn.can_undo?
    assert_raises(Draughts::IllegalMove) { drawn.undo }
    assert_equal 8, drawn.plies, "the finished game is untouched"
    assert_equal :draw, drawn.result

    resigned = Game.new
    resigned.play("11-15")
    resigned.resign(Side::WHITE)

    refute resigned.can_undo?
    assert_raises(Draughts::IllegalMove) { resigned.undo }
    assert_equal :red_won, resigned.result
    assert_equal 1, resigned.plies
  end

  # Undo must put back the occurrence count of the position it LEFT, not only the one it
  # lands on, or a position that has occurred twice reads as three and draws too early.
  def test_undo_decrements_the_occurrence_count_of_the_position_it_left
    start = Position.build({ 4 => "R", 29 => "W" }, Side::RED)
    game = Game.new(start)
    [ "4-8", "29-25", "8-4", "25-29" ].each { |text| game.play(text) }

    assert_equal start, game.position
    assert_equal 2, game.occurrence_count(start), "the cycle brought the start back once"
    assert_nil game.result

    game.undo

    assert_equal 1, game.occurrence_count(start), "undo gave back the occurrence it left"
    assert_equal 3, game.plies
    assert_equal Position.build({ 4 => "R", 25 => "W" }, Side::WHITE), game.position
    assert_equal 1, game.occurrence_count
    assert game.can_undo?

    # and the consequence: replaying the same ply reaches the second occurrence, not a draw
    game.play("25-29")
    assert_equal 2, game.occurrence_count(start)
    assert_nil game.result, "the position has occurred twice, so this is not a threefold draw"
  end

  def test_undo_after_a_capture_puts_the_captured_pieces_back
    game = Game.new(Position.build({ 4 => "r", 8 => "w", 15 => "w", 29 => "W" }, Side::RED))
    game.quiet_plies = 9
    game.play("4x11x18")

    assert_equal 0, game.quiet_plies
    game.undo

    assert_equal Piece::WHITE_MAN, game.position.at(8)
    assert_equal Piece::WHITE_MAN, game.position.at(15)
    assert_equal Piece::RED_MAN, game.position.at(4)
    assert_equal 9, game.quiet_plies
  end

  def test_undo_clears_a_pending_path
    game = Game.new(Position.build({ 4 => "r", 8 => "w", 15 => "w", 29 => "W" }, Side::WHITE))
    game.play("29-25")
    game.play_leg(4, 11)
    assert game.pending?

    game.undo
    refute game.pending?
    assert_equal 0, game.plies
  end

  # -- rebuilding from stored state ---------------------------------------------------

  def test_restore_rebuilds_a_game_from_its_stored_columns
    played = Game.new
    [ "11-15", "22-18", "15x22", "25x18" ].each { |text| played.play(text) }
    keys = [ Position.start.key ] + played.moves.each_with_index.map do |_, index|
      replay = Game.new
      played.moves.first(index + 1).each { |move| replay.play(move.pdn) }
      replay.position.key
    end

    restored = Game.restore(position: played.position.key,
                            quiet_plies: played.quiet_plies,
                            moves: played.moves.map(&:pdn),
                            positions: keys)

    assert_equal played.position, restored.position
    assert_equal played.plies, restored.plies
    assert_equal played.moves.map(&:pdn), restored.moves.map(&:pdn)
    assert_equal played.quiet_plies, restored.quiet_plies
    assert_equal played.occurrences, restored.occurrences
    assert_equal played.legal_moves.map(&:pdn), restored.legal_moves.map(&:pdn)

    restored.undo
    assert_equal "15x22", restored.moves.last.pdn
    assert_equal 3, restored.plies
  end

  def test_restore_accepts_bare_board_strings_and_a_separate_side
    played = Game.new
    boards = [ Position.start.board_string ]
    [ "11-15", "22-18" ].each do |text|
      played.play(text)
      boards << played.position.board_string
    end

    restored = Game.restore(position: played.position.board_string, side: :red,
                            moves: played.moves, positions: boards)

    assert_equal played.position, restored.position
    assert_equal 2, restored.plies
    assert_equal 1, restored.occurrence_count
    assert_equal played.occurrences, restored.occurrences,
                 "a bare board string takes its side to move from the ply it sits on"
  end

  def test_restore_keeps_a_pending_path_and_a_finished_result
    position = Position.build({ 4 => "r", 8 => "w", 15 => "w", 29 => "W" }, Side::RED)
    pending = Game.restore(position: position, pending_path: [ 4, 11 ])

    assert pending.pending?
    assert_equal [ 4, 11 ], pending.pending_path
    assert_equal [ 18 ], pending.legal_targets(11)
    assert_equal [], pending.legal_targets(4)

    finished = Game.restore(position: Position.start, result: "red_won", reason: "resignation")
    assert finished.finished?
    assert_equal :red_won, finished.result
    assert_equal :resignation, finished.reason
  end

  def test_restore_resolves_move_text_against_the_position_it_was_played_from
    # PDN text alone does not say whether a move crowned a man; resolving it against the
    # position it was played from does.
    start = Position.build({ 27 => "r", 1 => "W", 5 => "W" }, Side::RED)
    played = Game.new(start)
    played.play("27-32")

    restored = Game.restore(position: played.position, moves: [ "27-32" ],
                            positions: [ start.key, played.position.key ])

    assert restored.moves.last.promotion?
    assert_equal 32, restored.moves.last.destination
    restored.undo
    assert_equal start, restored.position
  end

  def test_a_game_can_be_built_from_a_position_key_or_a_position
    from_key = Game.new("rrrrrrrrrrrr--------wwwwwwwwwwww r")

    assert_equal Position.start, from_key.position
    assert_equal Position.start, Game.new(Position.start).position
  end

  def test_occurrence_counting_uses_the_position_key
    game = Game.new(Position.build({ 4 => "R", 29 => "W" }, Side::RED))
    game.play("4-8")
    game.play("29-25")

    assert_equal 1, game.occurrence_count
    assert_equal 1, game.occurrence_count(Position.build({ 4 => "R", 29 => "W" }, Side::RED))
    assert_equal 3, game.occurrences.values.sum
    assert_equal 0, game.occurrence_count(Position.start)
  end

  # M1: undo after a restore must give exactly what a game played forward gives, including
  # when the stored history starts part way through a quiet run.
  def test_undo_after_a_restore_restores_the_stored_quiet_ply_count
    start = Position.build({ 4 => "R", 29 => "W", 13 => "r" }, Side::RED)
    played = Game.new(start)
    played.quiet_plies = 40
    keys = [ start.key ]
    [ "4-8", "29-25" ].each do |text|
      played.play(text)
      keys << played.position.key
    end

    assert_equal 42, played.quiet_plies

    restored = Game.restore(position: played.position, quiet_plies: played.quiet_plies,
                            moves: played.moves.map(&:pdn), positions: keys)

    assert_equal 42, restored.quiet_plies
    assert restored.can_undo?
    restored.undo
    played.undo
    assert_equal 41, restored.quiet_plies, "one undo goes back to 41, not to 1"
    assert_equal played.quiet_plies, restored.quiet_plies
    restored.undo
    played.undo
    assert_equal 40, restored.quiet_plies
    assert_equal played.quiet_plies, restored.quiet_plies
    assert_equal start, restored.position
  end

  def test_restore_takes_the_counter_at_the_start_of_a_partial_history
    start = Position.build({ 4 => "R", 29 => "W" }, Side::RED)
    played = Game.new(start)
    played.quiet_plies = 77
    keys = [ start.key ]
    [ "4-8", "29-25" ].each do |text|
      played.play(text)
      keys << played.position.key
    end

    told = Game.restore(position: played.position, quiet_plies: 79, start_quiet_plies: 77,
                        moves: played.moves.map(&:pdn), positions: keys)
    told.undo
    assert_equal 78, told.quiet_plies
    told.undo
    assert_equal 77, told.quiet_plies

    error = assert_raises(Draughts::InvalidPosition) do
      Game.restore(position: played.position, quiet_plies: 79, start_quiet_plies: 3,
                   moves: played.moves.map(&:pdn), positions: keys)
    end
    assert_includes error.message, "start_quiet_plies"
  end

  # A stored counter that contradicts the history it came with cannot be repaired: counting
  # back from it runs below zero. Those plies refuse undo instead of inventing a number.
  def test_a_stored_counter_that_contradicts_its_history_refuses_undo_rather_than_guess
    start = Position.build({ 4 => "R", 29 => "W" }, Side::RED)
    played = Game.new(start)
    played.quiet_plies = 50
    keys = [ start.key ]
    [ "4-8", "29-25", "8-4" ].each do |text|
      played.play(text)
      keys << played.position.key
    end

    assert_equal 53, played.quiet_plies, "three quiet king moves"

    restored = Game.restore(position: played.position, quiet_plies: 1,
                            moves: played.moves.map(&:pdn), positions: keys)

    assert_equal 1, restored.quiet_plies
    assert restored.can_undo?
    restored.undo
    assert_equal 0, restored.quiet_plies, "one ply back is still recoverable"
    refute restored.can_undo?, "two plies back would need a negative counter"
    error = assert_raises(Draughts::IllegalMove) { restored.undo }
    assert_includes error.message, "start_quiet_plies"
    assert_equal 2, restored.plies, "the refused undo changed nothing"
  end

  # The counter before the first capture or man move of a history is the one thing stored
  # data cannot settle, so positions: means what it says (the match from its own start) and
  # a later window says so with start_quiet_plies:.
  def test_a_history_that_starts_where_the_game_started_needs_no_extra_argument
    played = Game.new
    keys = [ Position.start.key ]
    [ "11-15", "22-18", "15x22", "25x18", "12-16" ].each do |text|
      played.play(text)
      keys << played.position.key
    end

    restored = Game.restore(position: played.position, quiet_plies: played.quiet_plies,
                            moves: played.moves.map(&:pdn), positions: keys)

    5.times do
      played.undo
      restored.undo
      assert_equal played.quiet_plies, restored.quiet_plies
      assert_equal played.position, restored.position
    end
    assert_equal 0, restored.plies
    assert_equal 0, restored.quiet_plies
    assert_equal Position.start, restored.position
  end

  # M3: a stored pending path that is not an unfinished legal move would lock the game to a
  # square with no continuation and no way out, so restore refuses it.
  def test_restore_refuses_a_pending_path_that_is_not_an_unfinished_legal_move
    position = Position.build({ 4 => "r", 8 => "w", 15 => "w", 29 => "W" }, Side::RED)

    ok = Game.restore(position: position, pending_path: [ 4, 11 ])
    assert ok.pending?
    assert_equal [ 18 ], ok.legal_targets(11)

    [ [ 1, 5 ], [ 4, 11, 18 ], [ 4 ], [ 11, 4 ] ].each do |path|
      error = assert_raises(Draughts::InvalidPosition, "path #{path.inspect}") do
        Game.restore(position: position, pending_path: path)
      end
      refute_empty error.message
    end

    assert_raises(Draughts::InvalidPosition) do
      Game.restore(position: Position.start, pending_path: [ 1, 5 ])
    end
    refute Game.restore(position: position, pending_path: []).pending?
    refute Game.restore(position: position, pending_path: nil).pending?
  end

  def test_restore_refuses_a_result_or_reason_that_is_not_a_pinned_name
    assert_raises(Draughts::InvalidPosition) do
      Game.restore(position: Position.start, result: "banana", reason: "resignation")
    end
    assert_raises(Draughts::InvalidPosition) do
      Game.restore(position: Position.start, result: "red_won", reason: "because")
    end
    assert_raises(Draughts::InvalidPosition) do
      Game.restore(position: Position.start, quiet_plies: -1)
    end

    fine = Game.restore(position: Position.start, result: :draw, reason: :agreement)
    assert_equal :draw, fine.result
    assert_equal :agreement, fine.reason
  end

  # Undo at scale, in the suite rather than in a probe: a long game played forward one leg at
  # a time and then undone all the way back, checking the position, the side to move, the
  # counter and the whole occurrence table at every step.
  def test_a_long_game_undoes_ply_by_ply_back_to_its_start
    random = Random.new(0xC0FFEE)
    game = Game.new
    trail = []

    60.times do
      break if game.finished?

      trail << [ game.position, game.quiet_plies, game.occurrences ]
      moves = game.legal_moves
      chosen = moves[random.rand(moves.length)]
      game.play(chosen)
    end

    refute game.finished?, "this seeded game must stop short of a result so undo is allowed"
    assert_equal 60, game.plies
    assert_equal 60, trail.length

    trail.reverse_each do |position, quiet, occurrences|
      game.undo
      assert_equal position, game.position
      assert_equal position.side_to_move, game.side_to_move
      assert_equal quiet, game.quiet_plies
      assert_equal occurrences, game.occurrences
    end

    assert_equal 0, game.plies
    assert_equal Position.start, game.position
    assert_equal 1, game.occurrence_count
    assert_raises(Draughts::IllegalMove) { game.undo }
  end

  def test_inspect_names_the_position_and_the_counters
    game = Game.new

    assert_includes game.inspect, Position.start.key
    assert_includes game.inspect, "plies=0"
  end
end
