# frozen_string_literal: true

module Draughts
  # PDN square numbering and the diagonal geometry built on it.
  #
  # Squares are the Integers 1 to 32 everywhere in the engine and everywhere the Rails
  # application stores one. Column and row are both counted from Red's bottom-left corner
  # starting at 0, a square is playable when (column + row) is even, and the number of a
  # playable square is
  #
  #   4 * row + (3 - column / 2) + 1        (integer division)
  #
  # so square 1 is the near-right corner from Red's seat (column 6, row 0), the numbers run
  # right to left along each row and then row by row upward, Red starts on 1 to 12 and White
  # on 21 to 32. Squares 1 to 4 are row 0 (White's promotion row) and 29 to 32 are row 7
  # (Red's promotion row).
  module Square
    BOARD_SIZE = 8
    COUNT = 32
    ALL = (1..COUNT).to_a.freeze
    RANGE = (1..COUNT).freeze

    # Diagonal directions as [column delta, row delta], indexed 0 to 3. "Up" is toward row 7,
    # which is the direction Red men move; White men move down.
    DIRECTIONS = [ [ -1, -1 ], [ 1, -1 ], [ -1, 1 ], [ 1, 1 ] ].freeze
    DOWN_LEFT = 0
    DOWN_RIGHT = 1
    UP_LEFT = 2
    UP_RIGHT = 3
    KING_DIRECTIONS = [ DOWN_LEFT, DOWN_RIGHT, UP_LEFT, UP_RIGHT ].freeze
    MAN_DIRECTIONS = {
      Side::RED => [ UP_LEFT, UP_RIGHT ].freeze,
      Side::WHITE => [ DOWN_LEFT, DOWN_RIGHT ].freeze
    }.freeze

    # True for a coordinate pair on the board.
    def self.valid?(col, row)
      col >= 0 && col < BOARD_SIZE && row >= 0 && row < BOARD_SIZE
    end

    # True for a dark square that can hold a piece.
    def self.playable?(col, row)
      valid?(col, row) && (col + row).even?
    end

    # True for an Integer in 1..32.
    def self.number?(value)
      value.is_a?(Integer) && value >= 1 && value <= COUNT
    end

    # The PDN number of a playable coordinate pair. Raises for anything else.
    def self.number(col, row)
      raise InvalidPosition, "not a playable square: (#{col}, #{row})" unless playable?(col, row)

      4 * row + (3 - col / 2) + 1
    end

    # The PDN number of a coordinate pair, or nil when it is off the board or a light square.
    # This is the safe read the Java model spelled pieceAt(col, row).
    def self.at(col, row)
      return nil unless playable?(col, row)

      4 * row + (3 - col / 2) + 1
    end

    COLUMNS = Array.new(COUNT + 1)
    ROWS = Array.new(COUNT + 1)
    (1..COUNT).each do |number|
      index = number - 1
      row = index / 4
      COLUMNS[number] = (3 - index % 4) * 2 + row % 2
      ROWS[number] = row
    end
    COLUMNS.freeze
    ROWS.freeze

    def self.column(number)
      COLUMNS[check_number(number)]
    end

    def self.row(number)
      ROWS[check_number(number)]
    end

    def self.coordinates(number)
      [ COLUMNS[check_number(number)], ROWS[number] ]
    end

    # Returns the number when it is a square number 1 to 32, raises InvalidPosition otherwise.
    def self.check_number(number)
      raise InvalidPosition, "not a square number: #{number.inspect}" unless number?(number)

      number
    end

    # STEPS[square][direction] is the adjacent square in that direction, or nil at an edge.
    # JUMPS[square][direction] is [jumped square, landing square], or nil when the jump
    # would leave the board. MIDPOINTS[from][to] is the square jumped over when `to` is a
    # jump landing from `from`, and nil otherwise.
    STEPS = Array.new(COUNT + 1) { Array.new(4) }
    JUMPS = Array.new(COUNT + 1) { Array.new(4) }
    MIDPOINTS = Array.new(COUNT + 1) { Array.new(COUNT + 1) }
    (1..COUNT).each do |number|
      col = COLUMNS[number]
      row = ROWS[number]
      DIRECTIONS.each_with_index do |(dcol, drow), direction|
        step = at(col + dcol, row + drow)
        STEPS[number][direction] = step
        landing = at(col + 2 * dcol, row + 2 * drow)
        next if step.nil? || landing.nil?

        JUMPS[number][direction] = [ step, landing ].freeze
        MIDPOINTS[number][landing] = step
      end
      STEPS[number].freeze
      JUMPS[number].freeze
      MIDPOINTS[number].freeze
    end
    STEPS.freeze
    JUMPS.freeze
    MIDPOINTS.freeze

    # The adjacent square in one direction, or nil.
    def self.step(number, direction)
      STEPS[check_number(number)][direction]
    end

    # [jumped square, landing square] in one direction, or nil.
    def self.jump(number, direction)
      JUMPS[check_number(number)][direction]
    end

    # The square jumped over when moving from one square to a jump landing, or nil when the
    # two squares are not two diagonal steps apart.
    def self.midpoint(from, to)
      MIDPOINTS[check_number(from)][check_number(to)]
    end

    # The directions a piece may use.
    def self.directions(side, king)
      return KING_DIRECTIONS if king

      MAN_DIRECTIONS.fetch(side) { raise InvalidPosition, "not a side: #{side.inspect}" }
    end

    # The row a man of this side promotes on: 7 for Red, 0 for White.
    def self.promotion_row(side)
      side == Side::RED ? BOARD_SIZE - 1 : 0
    end

    # True when landing on this square promotes a man of this side (29 to 32 for Red,
    # 1 to 4 for White).
    def self.promotion?(number, side)
      case side
      when Side::RED then number >= 29
      when Side::WHITE then number <= 4
      else raise InvalidPosition, "not a side: #{side.inspect}"
      end
    end
  end
end
