# frozen_string_literal: true

module Draughts
  # An immutable man or king. There are only four pieces in the game, so Piece is a
  # flyweight: Piece[side, king] always returns the same frozen instance, promote returns the
  # identical object when the piece is already a king, and equality is value equality.
  class Piece
    CHARS = { [ Side::RED, false ] => "r", [ Side::RED, true ] => "R",
              [ Side::WHITE, false ] => "w", [ Side::WHITE, true ] => "W" }.freeze

    attr_reader :side

    # Use Piece[side, king], Piece.man, Piece.king or Piece.from_char: the four pieces are
    # built once, below, and new is private from then on.
    def initialize(side, king)
      @side = side
      @king = king
      @char = CHARS.fetch([ side, king ]) { raise InvalidPosition, "no such piece" }
      freeze
    end

    def king?
      @king
    end

    def man?
      !@king
    end

    # The character this piece takes in a position string.
    def char
      @char
    end

    # A king of the same side. Already a king: the very same object.
    def promote
      @king ? self : BY_SIDE_AND_KING.fetch([ @side, true ])
    end

    def opponent_side
      Side.opponent(@side)
    end

    def ==(other)
      other.is_a?(Piece) && other.side == @side && other.king? == @king
    end
    alias eql? ==

    def hash
      [ Piece, @side, @king ].hash
    end

    def to_s
      @char
    end

    def inspect
      "#<Draughts::Piece #{@char}>"
    end

    RED_MAN = new(Side::RED, false)
    RED_KING = new(Side::RED, true)
    WHITE_MAN = new(Side::WHITE, false)
    WHITE_KING = new(Side::WHITE, true)

    ALL = [ RED_MAN, RED_KING, WHITE_MAN, WHITE_KING ].freeze
    BY_CHAR = ALL.to_h { |piece| [ piece.char, piece ] }.freeze
    BY_SIDE_AND_KING = ALL.to_h { |piece| [ [ piece.side, piece.king? ], piece ] }.freeze

    private_class_method :new

    # The canonical piece. Piece[:red, true] is the Red king.
    def self.[](side, king = false)
      BY_SIDE_AND_KING.fetch([ side, king ]) do
        raise InvalidPosition, "no such piece: #{side.inspect}, king=#{king.inspect}"
      end
    end

    def self.man(side)
      self[side, false]
    end

    def self.king(side)
      self[side, true]
    end

    # Accepts "r", "R", "w" or "W".
    def self.from_char(char)
      BY_CHAR.fetch(char) { raise InvalidPosition, "not a piece character: #{char.inspect}" }
    end

    # Normalizes what a fixture or a caller might hand over to a Piece: a Piece, a position
    # string character ("r", "R", "w", "W"), or a Symbol (:red, :red_man, :red_king, :white,
    # :white_man, :white_king).
    def self.cast(spec)
      case spec
      when Piece then spec
      when String then from_char(spec)
      when :red, :red_man then RED_MAN
      when :red_king then RED_KING
      when :white, :white_man then WHITE_MAN
      when :white_king then WHITE_KING
      else raise InvalidPosition, "not a piece: #{spec.inspect}"
      end
    end
  end
end
