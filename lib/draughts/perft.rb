# frozen_string_literal: true

module Draughts
  # The perft node counter: how many distinct move sequences of a given length exist from a
  # position. A complete jump sequence counts as one node and promotion ends the move, which
  # is the convention the published English draughts numbers assume. From the starting
  # position they are
  #
  #   depth  1    2    3     4      5       6        7
  #   nodes  7   49  302  1469   7361   36768   179740
  #
  # No incorrect move generator reproduces all of them, which is why this counter exists.
  # The expected counts are deliberately not a constant here. test/draughts/perft_test.rb and
  # test/draughts_runner.rb each write the numbers out as literals, so neither can be made to
  # compare the engine against a table the engine itself supplies.
  module Perft
    # Nodes at exactly this depth. Depth 0 is the position itself, one node.
    def self.count(position, depth)
      raise InvalidPosition, "perft depth cannot be negative" if depth.negative?
      return 1 if depth.zero?

      moves = Rules.legal_moves(position)
      return moves.length if depth == 1

      total = 0
      moves.each { |move| total += count(Rules.apply(position, move), depth - 1) }
      total
    end

    # The node count under each legal move, keyed by PDN text. The sum is count(position,
    # depth), so a divide against a reference tells you which move generation went wrong.
    def self.divide(position, depth)
      raise InvalidPosition, "perft divide needs a depth of at least 1" if depth < 1

      Rules.legal_moves(position).to_h do |move|
        [ move.pdn, count(Rules.apply(position, move), depth - 1) ]
      end
    end
  end
end
