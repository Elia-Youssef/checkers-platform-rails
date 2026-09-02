# frozen_string_literal: true

module Draughts
  # Move generation and move application: the only place in this repository where the rules
  # of English draughts are decided.
  #
  # The rules, all of them:
  #   a man steps one square diagonally forward and captures forward only;
  #   a king steps and captures one square in all four diagonal directions, never further;
  #   captures are mandatory across the whole side, so one available jump refuses every
  #     quiet move, including quiet moves of pieces that cannot jump;
  #   a jumping piece must keep jumping with that same piece until it cannot, and the whole
  #     sequence is one move; the player chooses freely among first jumps and continuations;
  #   a jumped piece stays on the board until the move ends, so no piece is jumped twice and
  #     nothing may land on a square a jumped piece still occupies; the origin square is
  #     empty from the first leg on, so a sequence may end where it began;
  #   a man that reaches the far row is crowned, and promotion during a jump ends the move.
  #
  # Generation is deterministic: moves come back ordered by origin square and then by their
  # square path, so the opening position always yields 9-13, 9-14, 10-14, 10-15, 11-15,
  # 11-16, 12-16 in that order.
  module Rules
    EMPTY_BYTE = Position::EMPTY_BYTE
    BYTE_SIDE = Position::BYTE_SIDE
    BYTE_KING = Position::BYTE_KING
    JUMPS = Square::JUMPS
    STEPS = Square::STEPS
    MIDPOINTS = Square::MIDPOINTS

    # What one accepted leg did: the path so far (origin plus every landing square), whether
    # the jump sequence is now finished, and the completed Move when it is.
    LegResult = Data.define(:path, :complete, :move) do
      def complete?
        complete
      end

      def pending?
        !complete
      end
    end

    # Every legal move for the side to move, as complete moves.
    def self.legal_moves(position)
      board = position.board_string
      side = position.side_to_move
      opponent = Side.opponent(side)
      moves = []

      1.upto(Square::COUNT) do |origin|
        byte = board.getbyte(origin - 1)
        next unless BYTE_SIDE[byte] == side

        king = BYTE_KING[byte]
        paths = []
        search_captures(board, side, opponent, king, Square.directions(side, king),
                        origin, origin, [], [ origin ], paths)
        next if paths.empty?

        paths.sort!
        paths.each { |path| moves << capture_move(side, king, path) }
      end
      return moves unless moves.empty?

      1.upto(Square::COUNT) do |origin|
        byte = board.getbyte(origin - 1)
        next unless BYTE_SIDE[byte] == side

        king = BYTE_KING[byte]
        steps = STEPS[origin]
        targets = []
        Square.directions(side, king).each do |direction|
          target = steps[direction]
          targets << target if target && board.getbyte(target - 1) == EMPTY_BYTE
        end
        targets.sort!
        targets.each do |target|
          moves << Move.new(origin: origin, landings: [ target ].freeze, captures: [].freeze,
                            promotion: !king && Square.promotion?(target, side))
        end
      end
      moves
    end

    # The legal moves that start on one square. Mandatory capture still applies across the
    # whole side, so a piece with a quiet move but no jump returns nothing while another
    # piece can jump.
    def self.legal_moves_from(position, square)
      Square.check_number(square)
      legal_moves(position).select { |move| move.origin == square }
    end

    # The squares a piece may move to with its next leg, in ascending order. This is what a
    # board shows as destination dots for a selected piece.
    def self.legal_targets(position, square)
      legal_moves_from(position, square).map { |move| move.landings.first }.uniq
    end

    # Every square that has a legal move, with the squares it may move to, in one pass over
    # the generator: { origin => [target, ...] } in ascending order both ways. A piece with
    # no legal move is simply absent, so a page can render the whole board from this hash
    # without asking a rules question per square.
    def self.targets_by_origin(position)
      legal_moves(position).each_with_object({}) do |move, out|
        targets = (out[move.origin] ||= [])
        target = move.landings.first
        targets << target unless targets.include?(target)
      end
    end

    # True when the side to move has at least one jump, so every quiet move is refused.
    def self.capture_available?(position)
      moves = legal_moves(position)
      !moves.empty? && moves.first.capture?
    end

    def self.legal?(position, move)
      legal_moves(position).include?(move)
    end

    # The legal move with this PDN text ("11-15", "24x15x8"), or nil. Accepts a Move too,
    # in which case it is returned when it is legal.
    def self.find_move(position, wanted)
      case wanted
      when Move then legal_moves(position).find { |move| move == wanted }
      else
        text = wanted.to_s.strip
        legal_moves(position).find { |move| move.pdn == text }
      end
    end

    # The move with this PDN text, or IllegalMove.
    def self.move!(position, wanted)
      find_move(position, wanted) ||
        raise(IllegalMove, "#{wanted} is not legal in #{position.key}")
    end

    # The position after a move: the piece leaves its origin, every captured piece is taken
    # off, the piece lands and is crowned if the move promotes, and the other side is to
    # move.
    #
    # This is the unchecked fast path, by decision: it trusts that the move came from
    # legal_moves for this position, because perft and the AI call it millions of times and a
    # second generation per node would halve the search. Handed a move that is not legal it
    # will happily produce nonsense. Everything a request can reach validates first:
    # find_move and legal? ask, move! and apply_leg raise IllegalMove, and Game#play and
    # Game#play_leg go through them. Callers outside the engine use those, never apply.
    # test_apply_is_the_unchecked_fast_path_and_the_named_entry_points_validate pins it.
    def self.apply(position, move)
      board = position.board_string.dup
      byte = board.getbyte(move.origin - 1)
      side = BYTE_SIDE[byte]
      raise IllegalMove, "no piece on square #{move.origin} in #{position.key}" if side.nil?

      board.setbyte(move.origin - 1, EMPTY_BYTE)
      move.captures.each { |square| board.setbyte(square - 1, EMPTY_BYTE) }
      byte = Position::PIECE_BYTE.fetch([ side, true ]) if move.promotion?
      board.setbyte(move.destination - 1, byte)
      Position.new(board.freeze, Side.opponent(side))
    end

    # ---- leg by leg -------------------------------------------------------------------
    # A web request commits one leg at a time. The server keeps the pending path (the origin
    # square plus every landing square so far) and asks these methods what may happen next,
    # so that legality is always recomputed from the stored position and never trusted to
    # the browser.

    # The complete legal moves whose square path starts with this pending path.
    def self.moves_matching(position, path)
      path = normalize_path(path)
      size = path.length
      legal_moves(position).select do |move|
        squares = move.squares
        squares.length >= size && squares.first(size) == path
      end
    end

    # The squares the pending path may continue to, in ascending order. With a path of just
    # the origin square this is the same as legal_targets.
    def self.continuations(position, path)
      path = normalize_path(path)
      size = path.length
      moves_matching(position, path).filter_map { |move| move.squares[size] }.uniq
    end

    # The move this path completes, or nil when the sequence must continue.
    def self.complete_move(position, path)
      path = normalize_path(path)
      moves_matching(position, path).find { |move| move.squares == path }
    end

    # Plays one leg from a pending path. Raises IllegalMove unless the extended path is the
    # start of at least one legal move.
    def self.apply_leg(position, path, to)
      path = normalize_path(path)
      Square.check_number(to)
      extended = (path + [ to ]).freeze
      candidates = moves_matching(position, extended)
      if candidates.empty?
        raise IllegalMove, "#{path.join(" to ")} to #{to} is not a legal leg in #{position.key}"
      end

      finished = candidates.find { |move| move.squares == extended }
      LegResult.new(path: extended, complete: !finished.nil?, move: finished)
    end

    # The squares captured so far by a pending path, from its geometry alone.
    def self.pending_captures(path)
      normalize_path(path).each_cons(2).filter_map { |from, to| MIDPOINTS[from][to] }
    end

    # The board as it stands part way through a jump sequence: the piece sits on the last
    # landing square and the pieces it has jumped are shown taken, with the same side still
    # to move. This is for rendering only. Legality during a sequence is always computed
    # from the stored position and the path, never from this board, because the rules keep a
    # jumped piece on the board until the move ends.
    def self.pending_position(position, path)
      path = normalize_path(path)
      return position if path.length < 2

      board = position.board_string.dup
      byte = board.getbyte(path.first - 1)
      side = BYTE_SIDE[byte]
      raise IllegalMove, "no piece on square #{path.first} in #{position.key}" if side.nil?

      board.setbyte(path.first - 1, EMPTY_BYTE)
      pending_captures(path).each { |square| board.setbyte(square - 1, EMPTY_BYTE) }
      if !BYTE_KING[byte] && Square.promotion?(path.last, side)
        byte = Position::PIECE_BYTE.fetch([ side, true ])
      end
      board.setbyte(path.last - 1, byte)
      Position.new(board.freeze, position.side_to_move)
    end

    def self.normalize_path(path)
      path = Array(path)
      raise InvalidPosition, "a path needs at least the origin square" if path.empty?

      path.each { |square| Square.check_number(square) }
      path
    end
    private_class_method :normalize_path

    # Depth-first search of every jump sequence from one square. taken holds the squares
    # already jumped in this sequence: those pieces are still on the board, so they may not
    # be jumped again and nothing may land on them. The origin square is treated as empty
    # because the moving piece left it.
    #
    # Promotion ends the move, and this search enforces it twice over. The explicit stop is
    # below; the structural one is that king and directions are the mover's own and never
    # change part way through a sequence, so a man keeps its two forward directions and, from
    # the far row, both of them leave the board. Removing the explicit stop alone therefore
    # changes nothing, which was measured: the whole suite and perft 1 to 8 stay green. What
    # the rule really forbids is the new king continuing with a king's four directions, and
    # that break does fail F3, grader line C and the ported Java case (see the phase 1
    # report). The stop stays because it says the rule out loud where a reader looks for it.
    def self.search_captures(board, side, opponent, king, directions, origin, from, taken, path, out)
      found = false
      jumps = JUMPS[from]
      directions.each do |direction|
        jump = jumps[direction]
        next if jump.nil?

        over, landing = jump
        next if landing != origin && board.getbyte(landing - 1) != EMPTY_BYTE
        next if taken.include?(over)
        next unless BYTE_SIDE[board.getbyte(over - 1)] == opponent

        found = true
        continued = path + [ landing ]
        if !king && Square.promotion?(landing, side)
          out << continued
        else
          search_captures(board, side, opponent, king, directions, origin, landing,
                          taken + [ over ], continued, out)
        end
      end
      out << path if !found && path.length > 1
    end
    private_class_method :search_captures

    def self.capture_move(side, king, path)
      captures = []
      previous = path.first
      path.each_with_index do |square, index|
        next if index.zero?

        captures << MIDPOINTS[previous][square]
        previous = square
      end
      Move.new(origin: path.first, landings: path[1..].freeze, captures: captures.freeze,
               promotion: !king && Square.promotion?(path.last, side))
    end
    private_class_method :capture_move
  end
end
