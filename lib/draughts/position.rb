# frozen_string_literal: true

module Draughts
  # An immutable board plus the side to move.
  #
  # The board is stored exactly as it is stored in the database and written in the rubric:
  # a 32-character string over PDN squares 1 to 32, "r" and "w" for men, "R" and "W" for
  # kings, "-" for an empty square. The starting position is
  #
  #   rrrrrrrrrrrr--------wwwwwwwwwwww    with Red to move
  #
  # The repetition key is that string together with the side to move, which is exactly what
  # equality and #hash use, so a Hash of positions counts occurrences for the threefold rule.
  class Position
    START_BOARD = "rrrrrrrrrrrr--------wwwwwwwwwwww"
    EMPTY_BOARD = ("-" * Square::COUNT).freeze
    BOARD_FORMAT = /\A[rRwW-]{32}\z/
    KEY_FORMAT = /\A([rRwW-]{32})[ _]?([rRwW])\z/

    # Low-level byte tables. Rules works on the board string directly through these, which
    # keeps move generation allocation-free; nothing outside the engine needs them.
    EMPTY_BYTE = "-".ord
    BYTE_SIDE = Array.new(256)
    BYTE_KING = Array.new(256, false)
    BYTE_PIECE = Array.new(256)
    Piece::ALL.each do |piece|
      byte = piece.char.ord
      BYTE_SIDE[byte] = piece.side
      BYTE_KING[byte] = piece.king?
      BYTE_PIECE[byte] = piece
    end
    BYTE_SIDE.freeze
    BYTE_KING.freeze
    BYTE_PIECE.freeze
    PIECE_BYTE = Piece::ALL.to_h { |piece| [ [ piece.side, piece.king? ], piece.char.ord ] }.freeze

    attr_reader :side_to_move

    # board is the 32-character string, side is :red or :white. Both are validated; the
    # string is frozen and never handed out unfrozen, so a Position cannot change.
    def initialize(board, side)
      board = board.to_s
      unless BOARD_FORMAT.match?(board)
        raise InvalidPosition, "a board is 32 characters over r, R, w, W and -: #{board.inspect}"
      end
      raise InvalidPosition, "not a side: #{side.inspect}" unless Side.valid?(side)

      @board = board.frozen? ? board : board.dup.freeze
      @side_to_move = side
      @hash = @board.hash ^ side.hash
      freeze
    end

    # The standard opening position with Red to move.
    def self.start
      @start ||= new(START_BOARD, Side::RED)
    end

    # An empty board with the given side to move. Useful for building fixtures.
    def self.empty(side = Side::RED)
      new(EMPTY_BOARD, side)
    end

    # Parses "rrrr...wwww r" (the repetition key) or a bare board string plus an explicit
    # side. Accepts a space or an underscore between the board and the side character.
    def self.parse(text, side = nil)
      text = text.to_s.strip
      if side.nil?
        match = KEY_FORMAT.match(text)
        raise InvalidPosition, "not a position key: #{text.inspect}" unless match

        new(match[1], Side.from_char(match[2]))
      else
        new(text, Side.cast(side))
      end
    end

    # Builds a position from a Hash of square number to piece. The piece may be a Piece, a
    # position-string character ("r", "R", "w", "W") or a Symbol (:red, :white, :red_king,
    # :white_king, :red_man, :white_man). Every other square is empty.
    #
    #   Position.build({ 11 => "r", 4 => "r", 15 => "w" }, :red)
    def self.build(pieces, side)
      board = EMPTY_BOARD.dup
      pieces.each do |square, spec|
        Square.check_number(square)
        board.setbyte(square - 1, Piece.cast(spec).char.ord)
      end
      new(board.freeze, Side.cast(side))
    end

    # The 32-character board string, frozen.
    def board_string
      @board
    end

    # The repetition key: the board string, a space, and "r" or "w".
    def key
      "#{@board} #{Side.char(@side_to_move)}"
    end
    alias to_s key

    # The piece on a square (1 to 32), or nil when the square is empty.
    def at(number)
      BYTE_PIECE[@board.getbyte(Square.check_number(number) - 1)]
    end
    alias [] at

    # The piece at a coordinate pair, or nil when the square is empty, unplayable or off the
    # board. This is the safe read that never raises.
    def at_coordinates(col, row)
      number = Square.at(col, row)
      number && BYTE_PIECE[@board.getbyte(number - 1)]
    end

    def empty?(number)
      @board.getbyte(Square.check_number(number) - 1) == EMPTY_BYTE
    end

    def occupied?(number)
      !empty?(number)
    end

    # :red, :white, or nil for an empty square.
    def side_at(number)
      BYTE_SIDE[@board.getbyte(Square.check_number(number) - 1)]
    end

    def king_at?(number)
      BYTE_KING[@board.getbyte(Square.check_number(number) - 1)]
    end

    # The number of pieces, of one side when a side is given.
    def count(side = nil)
      case side
      when nil then @board.count("rRwW")
      when Side::RED then @board.count("rR")
      when Side::WHITE then @board.count("wW")
      else raise InvalidPosition, "not a side: #{side.inspect}"
      end
    end

    def count_men(side)
      @board.count(Piece.man(side).char)
    end

    def count_kings(side)
      @board.count(Piece.king(side).char)
    end

    # The occupied squares, of one side when a side is given, in ascending PDN order.
    def squares(side = nil)
      result = []
      1.upto(Square::COUNT) do |number|
        occupant = BYTE_SIDE[@board.getbyte(number - 1)]
        result << number if occupant && (side.nil? || occupant == side)
      end
      result
    end

    # Yields [square number, piece] for every occupied square in ascending PDN order.
    def each_piece
      return enum_for(:each_piece) unless block_given?

      1.upto(Square::COUNT) do |number|
        piece = BYTE_PIECE[@board.getbyte(number - 1)]
        yield number, piece if piece
      end
      self
    end

    # A copy with one square changed. The piece may be nil (empty the square) or anything
    # Position.build accepts. The side to move does not change.
    def place(number, piece)
      board = @board.dup
      board.setbyte(Square.check_number(number) - 1,
                    piece.nil? ? EMPTY_BYTE : Piece.cast(piece).char.ord)
      self.class.new(board.freeze, @side_to_move)
    end

    # A copy with the other side to move (or the given side).
    def with_side(side = nil)
      side = side.nil? ? Side.opponent(@side_to_move) : Side.cast(side)
      side == @side_to_move ? self : self.class.new(@board, side)
    end

    def ==(other)
      other.is_a?(Position) && other.board_string == @board && other.side_to_move == @side_to_move
    end
    alias eql? ==

    def hash
      @hash
    end

    def inspect
      "#<Draughts::Position #{key}>"
    end
  end
end
