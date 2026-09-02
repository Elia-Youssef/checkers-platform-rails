# frozen_string_literal: true

require "minitest/autorun"
require "draughts"

# PDN move text, numbered move pairs and export. TASK-BRIEF.md section 1.7 pins the headers
# Event, Site, Date, Red, White, Result and GameType "21" and the result strings 1-0, 0-1
# and 1/2-1/2.
class DraughtsPdnTest < Minitest::Test
  include Draughts

  def test_move_text_for_quiet_single_capture_and_multi_jump_moves
    assert_equal "11-15", PDN.move_text(Move.new(origin: 11, landings: [ 15 ]))
    assert_equal "15x22", PDN.move_text(Move.new(origin: 15, landings: [ 22 ], captures: [ 18 ]))
    assert_equal "24x15x8",
                 PDN.move_text(Move.new(origin: 24, landings: [ 15, 8 ], captures: [ 19, 11 ]))
    assert_equal "11-15", PDN.move_text("11-15")
  end

  def test_numbered_move_pairs
    pairs = PDN.pairs(game_after("11-15", "22-18", "15x22", "25x18", "12-16").moves)

    assert_equal 3, pairs.length
    assert_equal [ 1, "11-15", "22-18" ], [ pairs[0].number, pairs[0].red, pairs[0].white ]
    assert_equal [ 2, "15x22", "25x18" ], [ pairs[1].number, pairs[1].red, pairs[1].white ]
    assert_equal [ 3, "12-16", nil ], [ pairs[2].number, pairs[2].red, pairs[2].white ]
  end

  def test_the_move_list_is_numbered_pairs_of_text
    game = game_after("11-15", "22-18", "15x22", "25x18")

    assert_equal "1. 11-15 22-18 2. 15x22 25x18", PDN.move_list(game.moves)
    assert_equal "", PDN.move_list([])
  end

  def test_a_move_list_that_starts_with_white_keeps_the_pairing
    moves = [ Move.new(origin: 22, landings: [ 18 ]), Move.new(origin: 11, landings: [ 15 ]) ]

    assert_equal "1. ... 22-18 2. 11-15", PDN.move_list(moves, first_side: Side::WHITE)
  end

  def test_result_strings
    assert_equal "1-0", PDN.result_string(:red_won)
    assert_equal "0-1", PDN.result_string(:white_won)
    assert_equal "1/2-1/2", PDN.result_string(:draw)
    assert_equal "*", PDN.result_string(nil)
    assert_raises(Draughts::InvalidPosition) { PDN.result_string(:abandoned) }
  end

  def test_export_carries_the_seven_headers_in_order_with_game_type_twenty_one
    game = game_after("11-15", "22-18", "15x22", "25x18")
    text = PDN.export(game, event: "Portfolio game", site: "checkers-ruby",
                      date: "2026.09.01", red: "Ada", white: "Grace")
    lines = text.lines.map(&:chomp)

    assert_equal [ '[Event "Portfolio game"]', '[Site "checkers-ruby"]', '[Date "2026.09.01"]',
                  '[Red "Ada"]', '[White "Grace"]', '[Result "*"]', '[GameType "21"]', "" ],
                 lines.first(8)
    assert_equal "1. 11-15 22-18 2. 15x22 25x18 *", lines[8]
    assert_equal %w[Event Site Date Red White Result GameType],
                 lines.first(7).map { |line| line[/\[(\w+)/, 1] }
  end

  def test_export_writes_each_of_the_three_result_strings
    red_win = finished_game { |game| game.resign(Side::WHITE) }
    white_win = finished_game { |game| game.resign(Side::RED) }
    draw = finished_game(&:agree_draw)

    assert_includes PDN.export(red_win), '[Result "1-0"]'
    assert_includes PDN.export(white_win), '[Result "0-1"]'
    assert_includes PDN.export(draw), '[Result "1/2-1/2"]'
    assert PDN.export(red_win).rstrip.end_with?(" 1-0"), "the result closes the move text"
    assert PDN.export(draw).rstrip.end_with?(" 1/2-1/2")
  end

  def test_export_defaults_and_date_handling
    text = PDN.export(Game.new)

    assert_includes text, '[Date "????.??.??"]'
    assert_includes text, '[Red "Red"]'
    assert_includes text, '[White "White"]'
    assert text.rstrip.end_with?("*"), "an unfinished game exports with the * result"

    with_date = PDN.export(Game.new, date: Time.at(0).utc)
    assert_includes with_date, '[Date "1970.01.01"]'
  end

  def test_export_escapes_quotes_in_a_display_name
    text = PDN.export(Game.new, red: 'Ada "Countess" Lovelace')

    assert_includes text, '[Red "Ada \"Countess\" Lovelace"]'
  end

  def test_a_long_move_list_wraps_at_eighty_columns
    moves = Array.new(30) { Move.new(origin: 24, landings: [ 15, 8 ], captures: [ 19, 11 ]) }
    text = PDN.move_list(moves)

    assert_operator text.lines.length, :>, 1, "the move text is wrapped"
    text.lines.each { |line| assert_operator line.chomp.length, :<=, 80 }
    assert_equal 45, text.split(/\s+/).length, "15 numbers and 30 moves"
    assert_equal 1, PDN.move_list(moves, width: 1000).lines.length
  end

  def test_an_exported_file_wraps_its_move_text_too
    game = Game.restore(position: Position.start, moves: Array.new(30) { "24x15x8" })
    body = PDN.export(game).split(/\n\n/, 2).last
    tokens = body.split(/\s+/)

    body.lines.each { |line| assert_operator line.chomp.length, :<=, 80 }
    assert_equal PDN.move_list(game.moves).split(/\s+/), tokens[0..-2]
    assert_equal "*", tokens.last
  end

  private

  def game_after(*texts)
    game = Game.new
    texts.each { |text| game.play(text) }
    game
  end

  def finished_game
    game = Game.new
    game.play("11-15")
    game.play("22-18")
    yield game
    game
  end
end
