# frozen_string_literal: true

require "minitest/autorun"
require "draughts"

# The 32-character position string, the repetition key, and the lookups the board and the
# AI need. TASK-BRIEF.md section 1.2 pins the format and the starting position.
class DraughtsPositionTest < Minitest::Test
  include Draughts

  def test_the_starting_position_is_the_pinned_string_with_red_to_move
    start = Position.start
    assert_equal "rrrrrrrrrrrr--------wwwwwwwwwwww", start.board_string
    assert_equal Side::RED, start.side_to_move
    assert_equal "rrrrrrrrrrrr--------wwwwwwwwwwww r", start.key
    assert_equal 32, start.board_string.length
    assert_equal 12, start.count(Side::RED)
    assert_equal 12, start.count(Side::WHITE)
    assert_equal 24, start.count
    assert_equal 0, start.count_kings(Side::RED)
    assert_equal 0, start.count_kings(Side::WHITE)
  end

  def test_red_starts_on_one_to_twelve_and_white_on_twenty_one_to_thirty_two
    start = Position.start
    (1..12).each { |number| assert_equal Piece::RED_MAN, start.at(number), "square #{number}" }
    (13..20).each { |number| assert_nil start.at(number), "square #{number} is empty" }
    (21..32).each { |number| assert_equal Piece::WHITE_MAN, start.at(number), "square #{number}" }
  end

  def test_position_strings_round_trip_through_parse
    positions = [ Position.start, Position.start.with_side(Side::WHITE),
                 Position.build({ 4 => "R", 29 => "W", 13 => "r" }, Side::WHITE),
                 Position.empty(Side::RED) ]
    positions.each do |position|
      assert_equal position, Position.parse(position.key)
      assert_equal position, Position.parse(position.board_string, position.side_to_move)
      assert_equal position.key, Position.parse(position.key).key
    end
  end

  def test_parse_accepts_a_board_with_an_explicit_side_and_refuses_junk
    board = "rrrrrrrrrrrr--------wwwwwwwwwwww"
    assert_equal Side::WHITE, Position.parse(board, "w").side_to_move
    assert_equal Side::WHITE, Position.parse(board, :white).side_to_move
    assert_equal Side::RED, Position.parse("#{board}_r").side_to_move

    assert_raises(Draughts::InvalidPosition) { Position.parse("#{board}x") }
    assert_raises(Draughts::InvalidPosition) { Position.parse(board[0..30], :red) }
    assert_raises(Draughts::InvalidPosition) { Position.parse("#{board}z", nil) }
    assert_raises(Draughts::InvalidPosition) { Position.parse(board.tr("r", "q"), :red) }
    assert_raises(Draughts::InvalidPosition) { Position.new(board, :green) }
  end

  # The repetition rule compares the position string together with the side to move, so
  # equality and hash are exactly that pair and a Hash counts occurrences.
  def test_the_repetition_key_is_the_board_string_plus_the_side_to_move
    one = Position.build({ 4 => "R", 29 => "W" }, Side::RED)
    same = Position.parse(one.key)
    other_side = one.with_side(Side::WHITE)

    assert_equal one, same
    assert one.eql?(same)
    assert_equal one.hash, same.hash
    refute_equal one, other_side
    refute_equal one.key, other_side.key

    counts = Hash.new(0)
    [ one, same, other_side ].each { |position| counts[position] += 1 }
    assert_equal 2, counts[one]
    assert_equal 1, counts[other_side]
    assert_equal 2, counts.size
  end

  def test_lookups_by_square_and_by_coordinates
    position = Position.build({ 11 => "r", 15 => "W" }, Side::RED)

    assert_equal Piece::RED_MAN, position.at(11)
    assert_equal Piece::WHITE_KING, position[15]
    assert_nil position.at(1)
    assert_equal Side::RED, position.side_at(11)
    assert_nil position.side_at(1)
    refute position.king_at?(11)
    assert position.king_at?(15)
    assert position.empty?(1)
    assert position.occupied?(11)

    assert_equal Piece::RED_MAN, position.at_coordinates(*Square.coordinates(11))
    assert_nil position.at_coordinates(0, 1), "a light square holds nothing"
    assert_nil position.at_coordinates(-1, 0), "off the board reads as empty, it does not raise"
    assert_raises(Draughts::InvalidPosition) { position.at(0) }
    assert_raises(Draughts::InvalidPosition) { position.at(33) }
  end

  def test_counts_squares_and_each_piece
    position = Position.build({ 1 => "r", 11 => "R", 15 => "w", 29 => "W", 30 => "W" },
                              Side::RED)

    assert_equal 2, position.count(Side::RED)
    assert_equal 3, position.count(Side::WHITE)
    assert_equal 5, position.count
    assert_equal 1, position.count_men(Side::RED)
    assert_equal 1, position.count_kings(Side::RED)
    assert_equal 1, position.count_men(Side::WHITE)
    assert_equal 2, position.count_kings(Side::WHITE)
    assert_equal [ 1, 11 ], position.squares(Side::RED)
    assert_equal [ 15, 29, 30 ], position.squares(Side::WHITE)
    assert_equal [ 1, 11, 15, 29, 30 ], position.squares
    assert_equal [ [ 1, Piece::RED_MAN ], [ 11, Piece::RED_KING ], [ 15, Piece::WHITE_MAN ],
                  [ 29, Piece::WHITE_KING ], [ 30, Piece::WHITE_KING ] ],
                 position.each_piece.to_a
    assert_raises(Draughts::InvalidPosition) { position.count(:green) }
  end

  def test_build_accepts_pieces_characters_and_symbols_and_refuses_anything_else
    from_chars = Position.build({ 4 => "r", 29 => "W" }, Side::RED)
    from_symbols = Position.build({ 4 => :red_man, 29 => :white_king }, :red)
    from_pieces = Position.build({ 4 => Piece::RED_MAN, 29 => Piece::WHITE_KING }, Side::RED)

    assert_equal from_chars, from_symbols
    assert_equal from_chars, from_pieces
    assert_raises(Draughts::InvalidPosition) { Position.build({ 4 => "x" }, Side::RED) }
    assert_raises(Draughts::InvalidPosition) { Position.build({ 33 => "r" }, Side::RED) }
    assert_raises(Draughts::InvalidPosition) { Position.build({ 4 => 1 }, Side::RED) }
  end

  def test_a_position_is_immutable_and_place_and_with_side_return_copies
    start = Position.start
    moved = start.place(1, nil).place(5, "R")

    assert start.frozen?
    assert start.board_string.frozen?
    assert_equal "rrrrrrrrrrrr--------wwwwwwwwwwww", Position.start.board_string
    assert_equal Piece::RED_MAN, start.at(1)
    assert_nil moved.at(1)
    assert_equal Piece::RED_KING, moved.at(5)
    assert_equal Side::RED, moved.side_to_move

    flipped = start.with_side
    assert_equal Side::WHITE, flipped.side_to_move
    assert_equal start.board_string, flipped.board_string
    assert_same start, start.with_side(Side::RED)
    assert_equal Side::WHITE, start.with_side("w").side_to_move
  end

  def test_empty_board
    empty = Position.empty
    assert_equal "-" * 32, empty.board_string
    assert_equal 0, empty.count
    assert_equal Side::RED, empty.side_to_move
  end

  def test_to_s_and_inspect_show_the_key
    position = Position.start
    assert_equal position.key, position.to_s
    assert_includes position.inspect, position.key
  end
end
