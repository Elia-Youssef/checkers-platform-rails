# frozen_string_literal: true

# Draughts is a pure-Ruby rules engine for English / American draughts (checkers).
#
# It depends on nothing but the Ruby standard library: no Rails, no gems. The Rails
# application in this repository (module Checkers) is the only caller that knows about
# HTTP, storage or rendering; every legality decision, every move application and every
# terminal or draw check happens here.
#
# Board and notation
#   Only the 32 dark squares are playable and they carry the standard PDN numbers 1 to 32.
#   Red starts on 1 to 12 at the bottom and moves first, White starts on 21 to 32 at the top.
#   A position serializes to a 32-character string over "r", "R", "w", "W" and "-", which
#   together with the side to move is the repetition key and the stored position format.
#
# Layout
#   Draughts::Side      the two sides and their opposites
#   Draughts::Square    PDN numbering, coordinates, diagonal steps and jumps
#   Draughts::Piece     an immutable man or king
#   Draughts::Position  an immutable board plus the side to move
#   Draughts::Move      one complete move: origin, landing squares, captured squares
#   Draughts::Rules     legal move generation, leg-by-leg play, applying a move
#   Draughts::Game      a game in progress: history, draw counters, result, undo
#   Draughts::PDN       move text, numbered pairs, export with headers
#   Draughts::Perft     the node counter used to prove the generator correct
#   Draughts::AI        the computer opponent: evaluation, alpha-beta search, three levels
module Draughts
  # Included in every exception the engine raises on purpose, so that a caller can write
  # `rescue Draughts::Error` and still get ArgumentError semantics for malformed input.
  module Error; end

  # Raised when a position, square or piece cannot be built from the given input.
  class InvalidPosition < ArgumentError
    include Error
  end

  # Raised when a move or a single leg is not legal in the position it was offered for,
  # and when a game that has already finished is asked to play, undo or resign.
  # The Rails layer answers 422 to this.
  class IllegalMove < StandardError
    include Error
  end
end

require_relative "draughts/side"
require_relative "draughts/square"
require_relative "draughts/piece"
require_relative "draughts/position"
require_relative "draughts/move"
require_relative "draughts/rules"
require_relative "draughts/game"
require_relative "draughts/pdn"
require_relative "draughts/perft"
require_relative "draughts/ai"
