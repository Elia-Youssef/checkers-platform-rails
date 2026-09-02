# frozen_string_literal: true

module Draughts
  module AI
    # The static evaluation the search leans on: how good a position is for the side to
    # move, in centi-men, without searching anything.
    #
    # Two terms, and a third that only wakes up in the endgame.
    #
    #   material     a man is worth MAN_VALUE, a king KING_VALUE
    #   advancement  a man is worth ADVANCE_VALUE more per row it has crossed, so a Red man
    #                on row 0 is worth 100 and one on row 6 is worth 112; a man on its
    #                promotion row is never seen here because the move that lands there
    #                crowns it
    #   chase        only with ENDGAME_PIECES pieces or fewer on the board, and only for the
    #                side that is ahead on the first two terms: every king of the leading
    #                side loses CHASE_VALUE for each step of distance to the nearest enemy
    #                piece, which pushes the winning side to walk its kings at the loser
    #                instead of shuffling them until the forty-move rule fires; bounded by
    #                CHASE_BOUND, which is 147 and therefore larger than a man, see below
    #
    # The reference weights are pinned in TASK-BRIEF.md section 2 as "man 100 plus 2 per row
    # advanced, king 130" and marked tunable: RUBRIC.md item 9 grades strength, not weights.
    # The chase term is the fix CONCEPT.md section 6.2 recommends for the king endgame; it is
    # tunable and ungraded, and CHASE_ON turns it off in one place.
    #
    # Everything here is symmetrical: evaluating a position and evaluating its mirror with
    # the other side to move gives the same number with the opposite sign.
    module Evaluation
      MAN_VALUE = 100
      ADVANCE_VALUE = 2
      KING_VALUE = 130

      # The chase term, CONCEPT.md 6.2.
      #
      # Its size: at most ENDGAME_PIECES - 1 of the leader's pieces can be kings (the side
      # behind has to have something left to chase), and no square on an 8 by 8 board is
      # more than BOARD_SIZE - 1 diagonal steps from another, so the term cannot exceed
      # CHASE_BOUND = 3 x 7 x 7 = 147. That bound is reached, not merely allowed:
      # ---wR-------R-------R-------RRRR with Red to move puts seven Red kings on the seven
      # squares that are exactly seven steps from the White man on 4, and scores -147.
      #
      # So this term CAN outweigh a man in the extreme, and an earlier version of this
      # comment claimed the opposite (the session-2 audit's finding M2 measured the true
      # bound). What is true and what the term is built on: per king it is at most
      # CHASE_VALUE x 7 = 21, under a quarter of a man; it only wakes up with
      # ENDGAME_PIECES pieces or fewer and only when material is already unequal, so it
      # breaks ties in won and lost endgames rather than deciding material ones; and
      # measured over 535 endgame positions it changed the class of Medium's chosen move for
      # the worse on 4 of them and of Hard's on none. What it buys is in the report: 27 of
      # 30 won king endgames converted against 20 of 30 without it.
      CHASE_ON = true
      CHASE_VALUE = 3
      ENDGAME_PIECES = 8
      CHASE_BOUND = CHASE_VALUE * (ENDGAME_PIECES - 1) * (Square::BOARD_SIZE - 1)

      # MATERIAL[((square - 1) << 8) | byte] is what the piece stored as that byte on that
      # square is worth to Red: positive for a Red piece, negative for a White one, zero for
      # an empty square and for every byte that is not a piece character. One flat Array of
      # small Integers, so the inner loop is a single index per square with no branch.
      MATERIAL = Array.new(Square::COUNT << 8, 0)
      (1..Square::COUNT).each do |square|
        row = Square.row(square)
        base = (square - 1) << 8
        MATERIAL[base | Piece::RED_MAN.char.ord] = MAN_VALUE + (ADVANCE_VALUE * row)
        MATERIAL[base | Piece::RED_KING.char.ord] = KING_VALUE
        MATERIAL[base | Piece::WHITE_MAN.char.ord] =
          -(MAN_VALUE + (ADVANCE_VALUE * (Square::BOARD_SIZE - 1 - row)))
        MATERIAL[base | Piece::WHITE_KING.char.ord] = -KING_VALUE
      end
      MATERIAL.freeze

      # DISTANCE[a][b] is how many diagonal steps an unobstructed king needs to get from
      # square a to square b. Both squares are on the same colour complex, so the Chebyshev
      # distance over the coordinates is exactly that number of steps.
      DISTANCE = Array.new(Square::COUNT + 1) { Array.new(Square::COUNT + 1, 0) }
      (1..Square::COUNT).each do |from|
        from_col, from_row = Square.coordinates(from)
        (1..Square::COUNT).each do |to|
          to_col, to_row = Square.coordinates(to)
          DISTANCE[from][to] = [ (from_col - to_col).abs, (from_row - to_row).abs ].max
        end
        DISTANCE[from].freeze
      end
      DISTANCE.freeze

      # The score of a position for the side to move: positive is good for it.
      def self.evaluate(position)
        score = material(position)
        score += chase(position, score) if CHASE_ON
        position.side_to_move == Side::RED ? score : -score
      end

      # Material plus advancement from Red's point of view, whoever is to move. Positive
      # means Red is ahead.
      def self.material(position)
        board = position.board_string
        total = 0
        index = 0
        while index < Square::COUNT
          total += MATERIAL[(index << 8) | board.getbyte(index)]
          index += 1
        end
        total
      end

      # The endgame chase term from Red's point of view, given the material score from Red's
      # point of view. Zero unless the board is down to ENDGAME_PIECES pieces, one side is
      # ahead, and that side has a king to do the chasing.
      def self.chase(position, material_score)
        return 0 if material_score.zero?

        board = position.board_string
        return 0 if board.count("rRwW") > ENDGAME_PIECES

        leader = material_score.positive? ? Side::RED : Side::WHITE
        hunters = position.squares(leader).select { |square| position.king_at?(square) }
        return 0 if hunters.empty?

        quarry = position.squares(Side.opponent(leader))
        return 0 if quarry.empty?

        steps = 0
        hunters.each do |hunter|
          row = DISTANCE[hunter]
          nearest = Square::BOARD_SIZE
          quarry.each do |target|
            distance = row[target]
            nearest = distance if distance < nearest
          end
          steps += nearest
        end
        penalty = CHASE_VALUE * steps
        leader == Side::RED ? -penalty : penalty
      end

      # The three weights, for a caller that wants to print what the search is using.
      def self.weights
        { man: MAN_VALUE, advance: ADVANCE_VALUE, king: KING_VALUE,
          chase: CHASE_ON ? CHASE_VALUE : 0, endgame_pieces: ENDGAME_PIECES }
      end
    end
  end
end
