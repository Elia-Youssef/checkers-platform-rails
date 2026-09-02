# frozen_string_literal: true

module Draughts
  # The two sides. A side is a plain Symbol, :red or :white, so that it survives a round
  # trip through JSON, a database column or a form parameter without a wrapper object.
  # Red sits at the bottom of the board (rows 0 to 2), moves toward row 7 and moves first.
  module Side
    RED = :red
    WHITE = :white
    ALL = [ RED, WHITE ].freeze

    CHARS = { RED => "r", WHITE => "w" }.freeze
    LABELS = { RED => "Red", WHITE => "White" }.freeze
    FROM_CHAR = { "r" => RED, "R" => RED, "w" => WHITE, "W" => WHITE }.freeze

    # The other side. Raises InvalidPosition for anything that is not a side.
    def self.opponent(side)
      case side
      when RED then WHITE
      when WHITE then RED
      else raise InvalidPosition, "not a side: #{side.inspect}"
      end
    end

    def self.valid?(side)
      side == RED || side == WHITE
    end

    # "r" or "w", the character used in the position key.
    def self.char(side)
      CHARS.fetch(side) { raise InvalidPosition, "not a side: #{side.inspect}" }
    end

    # "Red" or "White", for PDN headers and any caller that wants a display name.
    def self.label(side)
      LABELS.fetch(side) { raise InvalidPosition, "not a side: #{side.inspect}" }
    end

    # Accepts "r", "R", "w", "W" and returns the side, or raises.
    def self.from_char(char)
      FROM_CHAR.fetch(char) { raise InvalidPosition, "not a side character: #{char.inspect}" }
    end

    # Normalizes anything a caller might hand over (a Symbol, a String, "r", "Red") to a side.
    def self.cast(value)
      return value if valid?(value)

      case value
      when String, Symbol
        text = value.to_s.downcase
        return RED if text == "red" || text == "r"
        return WHITE if text == "white" || text == "w"
      end
      raise InvalidPosition, "not a side: #{value.inspect}"
    end
  end
end
