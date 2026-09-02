# frozen_string_literal: true

module Draughts
  # One complete move.
  #
  # A quiet move has a single landing square and no captures. A jump has one landing square
  # per leg and one captured square per leg, and the whole sequence is a single Move: that is
  # what PDN writes (22x15x8), what the perft node counts assume, and what one row of the
  # moves table stores. The browser still commits a jump one leg at a time; Rules turns a
  # pending path back into the Move that finishes it.
  #
  # Squares are PDN numbers 1 to 32. promotion is true when this move crowns a man.
  class Move < Data.define(:origin, :landings, :captures, :promotion)
    def initialize(origin:, landings:, captures: [], promotion: false)
      Square.check_number(origin)
      raise InvalidPosition, "a move needs at least one landing square" if landings.empty?

      landings.each { |square| Square.check_number(square) }
      captures.each { |square| Square.check_number(square) }
      if !captures.empty? && captures.length != landings.length
        raise InvalidPosition, "a jump captures one piece per leg: #{landings.inspect} #{captures.inspect}"
      end

      super(origin: origin,
            landings: landings.frozen? ? landings : landings.dup.freeze,
            captures: captures.frozen? ? captures : captures.dup.freeze,
            promotion: promotion)
    end

    # The square the piece ends on.
    def destination
      landings.last
    end

    # Origin first, then every landing square: the squares PDN writes.
    def squares
      [ origin, *landings ]
    end

    def capture?
      !captures.empty?
    end

    def promotion?
      promotion
    end

    # How many pieces this move takes.
    def capture_count
      captures.length
    end

    # How many legs the move has (one for a quiet move, one per jump otherwise).
    def leg_count
      landings.length
    end

    # PDN text: "11-15" for a quiet move, "22x15x8" for a jump.
    def pdn
      squares.join(capture? ? "x" : "-")
    end
    alias to_s pdn

    def inspect
      "#<Draughts::Move #{pdn}#{promotion ? " promotion" : ""}>"
    end
  end
end
