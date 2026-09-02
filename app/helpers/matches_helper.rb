# Everything the match page needs to turn engine values into words and markup. No rule is
# decided here: the legal targets, the pending lock, the result and the reason all come from
# Draughts, and this only names them.
module MatchesHelper
  # The 64 cells of the board, top row first and left to right, so that Red (squares 1 to 12)
  # sits at the bottom. A cell is the PDN square number of a dark square, or nil for a light
  # square, which holds no piece and is not a control.
  def board_cells
    7.downto(0).flat_map do |row|
      (0..7).map { |column| Draughts::Square.at(column, row) }
    end
  end

  # "Square 11, Red man", "Square 5, White king", "Square 15, empty": the accessible name of a
  # board button, which names the square and what is on it.
  def square_label(number, piece)
    "Square #{number}, #{piece_name(piece)}"
  end

  def piece_name(piece)
    return "empty" if piece.nil?

    "#{Draughts::Side.label(piece.side)} #{piece.king? ? "king" : "man"}"
  end

  def side_label(side)
    Draughts::Side.label(Draughts::Side.cast(side))
  end

  # "Red to move" while a match is running.
  def turn_sentence(match)
    "#{side_label(match.side_to_move)} to move"
  end

  # The result and its reason in words: "White wins by resignation", "Red wins, no pieces
  # left", "Draw by threefold repetition".
  def result_sentence(match)
    return nil unless match.result.present?

    case match.result
    when "draw" then draw_sentence(match.reason)
    else "#{winner_label(match)} wins#{win_reason(match)}"
    end
  end

  def winner_label(match)
    match.result == "red_won" ? "Red" : "White"
  end

  def loser_label(match)
    match.result == "red_won" ? "White" : "Red"
  end

  # One entry of the move list: its ply number, so the latest can be highlighted, and its PDN
  # text, which the engine wrote.
  MoveEntry = Struct.new(:ply, :pdn)

  # The move list as numbered pairs, [number, red entry, white entry], Red first. The pairing
  # follows Draughts::PDN: a whole jump sequence is one entry because it is one move, and a
  # game whose first move was White's opens with an empty Red slot.
  def move_pairs(game)
    entries = game.moves.each_with_index.map { |move, index| MoveEntry.new(index + 1, move.pdn) }
    entries.unshift(nil) if first_mover(game) == Draughts::Side::WHITE
    entries.each_slice(2).with_index(1).map { |(red, white), number| [ number, red, white ] }
  end

  private
    # Which side played this game's first move, from the game's own history.
    def first_mover(game)
      game.plies.even? ? game.side_to_move : Draughts::Side.opponent(game.side_to_move)
    end

    def win_reason(match)
      case match.reason
      when "resignation" then " by resignation"
      when "no_pieces" then ", no pieces left"
      when "no_moves" then ", #{loser_label(match)} has no legal move"
      else ""
      end
    end

    def draw_sentence(reason)
      case reason
      when "agreement" then "Draw by agreement"
      when "threefold_repetition" then "Draw by threefold repetition"
      when "forty_move_rule" then "Draw by the forty-move rule"
      else "Draw"
      end
    end
end
