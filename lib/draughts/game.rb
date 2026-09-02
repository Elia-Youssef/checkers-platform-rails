# frozen_string_literal: true

module Draughts
  # A game in progress: the position, the moves played, the two draw counters, the pending
  # jump path and the result.
  #
  # A Game can always be rebuilt from what the Rails application stores, with Game.restore,
  # so no state lives only in memory. It plays either whole moves (the AI, tests, seeds) or
  # one leg at a time (the browser).
  #
  # After every completed move the terminal checks run in this fixed order:
  #   1. the side to move has no pieces      the other side wins, reason :no_pieces
  #   2. the side to move has no legal move  the other side wins, reason :no_moves
  #   3. this position with this side to move has now occurred three times, counting the
  #      starting position as its first occurrence, reason :threefold_repetition
  #   4. 80 consecutive plies have passed with no capture and no man move, reason
  #      :forty_move_rule (a promotion move is a man move, so it resets the counter)
  # Resignation and an agreed draw are set by the caller and are never overwritten.
  class Game
    # 80 consecutive plies with no capture and no man move: 40 moves by each side.
    QUIET_PLY_LIMIT = 80
    # The third occurrence of the same position with the same side to move.
    REPETITION_LIMIT = 3

    RESULTS = [ :red_won, :white_won, :draw ].freeze
    REASONS = [ :no_pieces, :no_moves, :resignation, :agreement,
                :threefold_repetition, :forty_move_rule ].freeze
    WINNER_RESULT = { Side::RED => :red_won, Side::WHITE => :white_won }.freeze

    # One played ply, kept so that undo can put everything back.
    Played = Data.define(:move, :position, :quiet_plies)

    attr_reader :position, :moves, :quiet_plies, :pending_path, :result, :reason

    def initialize(position = Position.start)
      @position = position.is_a?(Position) ? position : Position.parse(position)
      @moves = []
      @played = []
      @quiet_plies = 0
      @occurrences = Hash.new(0)
      @occurrences[@position.key] = 1
      @pending_path = nil
      @result = nil
      @reason = nil
      check_terminal
    end

    # Rebuilds a game from stored columns and rows.
    #
    #   position      the current position: a Position, a key string, or a board string with side:
    #   side          the side to move, when position is a bare board string
    #   quiet_plies   the stored counter for the forty-move rule, as it stands now
    #   moves         the completed moves in order, as Move objects or PDN strings; they are
    #                 not replayed, they are the history that undo and PDN export need
    #   positions     every position key that has occurred, oldest first, ending with the
    #                 current one; this is the match's start position followed by the
    #                 position after each move. Defaults to just the current position, which
    #                 counts it as its first occurrence.
    #   start_quiet_plies  the counter as it stood at the first entry of positions. Leave it
    #                 nil when the history starts where the game started, which is the normal
    #                 case and means 0; pass it when the history is a later window.
    #   pending_path  origin square plus the landing squares of the legs played so far. It is
    #                 validated against the position: it must be an unfinished legal move, or
    #                 InvalidPosition is raised.
    #   result/reason a finished game's outcome, checked against RESULTS and REASONS
    #
    # When moves and positions are both given and consistent, undo works all the way back and
    # restores exactly the counter a game played forward would have. See restored_counters
    # for what happens when the history is a later window and start_quiet_plies was not
    # given: undo is exact as far back as the counter can be recovered, and refused beyond
    # that, never wrong.
    def self.restore(position:, side: nil, quiet_plies: 0, moves: [], positions: nil,
                     start_quiet_plies: nil, pending_path: nil, result: nil, reason: nil)
      current = position.is_a?(Position) ? position : Position.parse(position, side)
      game = allocate
      game.send(:setup, current, quiet_plies.to_i, moves, positions, start_quiet_plies,
                pending_path, result, reason)
      game
    end

    def side_to_move
      @position.side_to_move
    end

    def plies
      @moves.length
    end

    # The move most recently completed, or nil.
    def last_move
      @moves.last
    end

    def finished?
      !@result.nil?
    end

    # :red, :white, or nil for a draw or an unfinished game.
    def winner
      case @result
      when :red_won then Side::RED
      when :white_won then Side::WHITE
      end
    end

    def drawn?
      @result == :draw
    end

    # True while a jump sequence is part way through.
    def pending?
      !@pending_path.nil?
    end

    # The square a pending sequence is locked to, or nil.
    def locked_square
      @pending_path&.last
    end

    # The board to draw: part way through a jump sequence the jumping piece is shown on its
    # last landing square with the pieces it has taken removed.
    def display_position
      pending? ? Rules.pending_position(@position, @pending_path) : @position
    end

    # How often a position has occurred, current position by default. The threefold rule
    # fires at REPETITION_LIMIT.
    def occurrence_count(position = @position)
      @occurrences[position.is_a?(Position) ? position.key : position.to_s]
    end

    # Every position key seen so far with its count, for storing or inspecting.
    def occurrences
      @occurrences.dup
    end

    # The legal moves now: none once the game is finished, and only the continuations of the
    # pending sequence while a jump is part way through.
    def legal_moves
      return [] if finished?
      return Rules.moves_matching(@position, @pending_path) if pending?

      Rules.legal_moves(@position)
    end

    # The squares a piece may move to now. Empty for every square but the locked one while a
    # jump sequence is pending, so no other piece can be selected.
    def legal_targets(square)
      Square.check_number(square)
      return [] if finished?

      if pending?
        return [] unless square == locked_square

        Rules.continuations(@position, @pending_path)
      else
        Rules.legal_targets(@position, square)
      end
    end

    # Every square that may be moved from now, with the squares it may move to. Empty once
    # the game is finished; while a jump sequence is pending it holds the locked square and
    # nothing else, so a board rendered from this hash cannot offer an illegal selection.
    def targets_by_square
      return {} if finished?
      return { locked_square => Rules.continuations(@position, @pending_path) } if pending?

      Rules.targets_by_origin(@position)
    end

    # Plays a complete move: a Move, or PDN text such as "11-15" or "24x15x8".
    def play(wanted)
      raise IllegalMove, "the game is finished" if finished?
      raise IllegalMove, "a jump sequence is pending on square #{locked_square}" if pending?

      move = Rules.find_move(@position, wanted)
      raise IllegalMove, "#{wanted} is not legal in #{@position.key}" if move.nil?

      record(move)
      move
    end

    # Plays one leg of a move, which is what one click sends. Returns a Rules::LegResult:
    # ask it whether the sequence is complete, and it carries the finished Move when it is.
    def play_leg(from, to)
      raise IllegalMove, "the game is finished" if finished?

      Square.check_number(from)
      if pending?
        unless from == locked_square
          raise IllegalMove, "the jump sequence is locked to square #{locked_square}"
        end
      elsif @position.side_at(from) != side_to_move
        raise IllegalMove, "square #{from} does not hold a piece of the side to move"
      end

      result = Rules.apply_leg(@position, @pending_path || [ from ], to)
      if result.complete?
        @pending_path = nil
        record(result.move)
      else
        @pending_path = result.path
      end
      result
    end

    # Takes back the last completed move, restoring the position, the side to move, the
    # quiet-ply counter, the repetition counts and the result. Also clears a pending path.
    def undo
      raise IllegalMove, "the game is finished" if finished?
      raise IllegalMove, "there is no move to undo" if @played.empty?

      if @played.last.quiet_plies.nil?
        raise IllegalMove,
              "this game was restored from a partial history, so the forty-move counter before " \
              "move #{@played.length} cannot be recovered: pass start_quiet_plies to restore"
      end

      @occurrences[@position.key] -= 1
      @occurrences.delete(@position.key) if @occurrences[@position.key] <= 0
      last = @played.pop
      @moves.pop
      @position = last.position
      @quiet_plies = last.quiet_plies
      @pending_path = nil
      @result = nil
      @reason = nil
      check_terminal
      last.move
    end

    def can_undo?
      !@played.empty? && !pending? && !finished? && !@played.last.quiet_plies.nil?
    end

    # Ends the game as a win for the other side. side is the side that resigns.
    def resign(side)
      raise IllegalMove, "the game is finished" if finished?

      finish(WINNER_RESULT.fetch(Side.opponent(Side.cast(side))), :resignation)
    end

    # Ends the game as a draw by agreement.
    def agree_draw
      raise IllegalMove, "the game is finished" if finished?

      finish(:draw, :agreement)
    end

    # Sets the forty-move counter, for rebuilding a game and for fixtures that start part
    # way through a quiet run. Re-runs the terminal checks.
    def quiet_plies=(count)
      count = Integer(count)
      raise InvalidPosition, "the quiet-ply count cannot be negative" if count.negative?

      @quiet_plies = count
      check_terminal
    end

    def inspect
      "#<Draughts::Game #{@position.key} plies=#{plies} quiet=#{@quiet_plies}" \
        "#{@result ? " #{@result}/#{@reason}" : ""}>"
    end

    private

    def setup(position, quiet_plies, moves, positions, start_quiet_plies, pending_path,
              result, reason)
      raise InvalidPosition, "the quiet-ply count cannot be negative" if quiet_plies.negative?

      @position = position
      @quiet_plies = quiet_plies
      @moves = moves.map { |move| move.is_a?(Move) ? move : parse_history_move(move) }
      @pending_path = restored_pending(pending_path)
      @occurrences = Hash.new(0)
      keys = restored_keys(positions)
      keys.each { |key| @occurrences[key] += 1 }
      @played = rebuild_played(keys, start_quiet_plies)
      @result = checked_name(result, RESULTS, "result")
      @reason = checked_name(reason, REASONS, "reason")
      check_terminal if @result.nil?
      self
    end

    # A stored result or reason must be one of the pinned names, so a typo or a stale column
    # is refused here instead of surfacing later as a broken PDN export.
    def checked_name(value, allowed, what)
      return nil if value.nil?

      name = value.to_sym
      return name if allowed.include?(name)

      raise InvalidPosition, "not a #{what}: #{value.inspect} (one of #{allowed.inspect})"
    end

    # A pending path is uncommitted state, so it is checked against the position it belongs
    # to: the origin and at least one landing square, and a strict prefix of some legal move,
    # which is exactly what apply_leg produces. Anything else would lock the game to a square
    # with no continuation and no way out.
    def restored_pending(path)
      return nil if path.nil? || (path.respond_to?(:empty?) && path.empty?)

      path = normalize_pending(path)
      if path.length < 2
        raise InvalidPosition,
              "a pending path needs the origin and at least one landing square: #{path.inspect}"
      end
      if Rules.continuations(@position, path).empty?
        raise InvalidPosition,
              "pending path #{path.inspect} is not an unfinished legal move in #{@position.key}"
      end

      path
    end

    # Every position key seen, oldest first. An entry may be a Position, a full key
    # ("<32 characters> r") or a bare 32-character board string, in which case the side to
    # move is inferred from how many plies later the current position is.
    def restored_keys(positions)
      return [ @position.key ] if positions.nil?

      total = positions.length
      positions.each_with_index.map do |entry, index|
        next entry.key if entry.is_a?(Position)

        text = entry.to_s.strip
        next text if Position::KEY_FORMAT.match?(text)

        side = (total - 1 - index).even? ? side_to_move : Side.opponent(side_to_move)
        Position.new(text, side).key
      end
    end

    # A stored history is the moves plus the position each one was played from, so undo can
    # be rebuilt exactly when both were stored. Without the positions the moves are still
    # kept for the move list and PDN export, but undo has nothing to restore. Resolving each
    # move against the position it was played from also recovers its captured squares and
    # its promotion flag when the history arrived as plain PDN text.
    def rebuild_played(keys, start_quiet_plies)
      return [] unless keys.length == @moves.length + 1

      befores = keys.first(@moves.length).map { |key| Position.parse(key) }
      @moves = @moves.each_with_index.map do |move, index|
        Rules.find_move(befores[index], move.pdn) || move
      end
      counters = restored_counters(befores, start_quiet_plies)
      @moves.each_with_index.map do |move, index|
        Played.new(move: move, position: befores[index], quiet_plies: counters[index])
      end
    end

    # counters[i] is the forty-move counter as it stood before move i was played, which is
    # what undo restores. What is recoverable from stored data alone is a fixed question, so
    # here is the whole argument.
    #
    # A capture or a man move sets the counter to 0, so the value after the last such move
    # depends only on the moves that follow it. Two consequences:
    #
    #   * If this history contains any reset, counting forward from 0 reaches the stored
    #     current counter whatever the history really started at, and every entry after the
    #     first reset is exact. The entries at and before the first reset are the only ones
    #     that depend on where the history began, and nothing in the stored data can settle
    #     them. positions: is documented as the match's start followed by every position
    #     after a move, so the default answer for them is 0, which is right for every game
    #     restored from its own beginning. A caller restoring a later window says so with
    #     start_quiet_plies:.
    #   * If this history contains no reset, counting forward from 0 misses the stored
    #     counter by exactly the amount the history started at, which is how a window is
    #     detected, and every entry is then recovered exactly by counting back from the
    #     stored counter.
    #
    # So a wrong entry is only ever possible in the first case, only before the first reset,
    # and only for a caller who passed a window without saying so. Counting back can still
    # run below zero when the stored counter contradicts the history; those entries are nil
    # and undo refuses them rather than inventing a number.
    def restored_counters(befores, start_quiet_plies)
      return [] if befores.empty?

      unless start_quiet_plies.nil?
        forward = counters_forward(befores, Integer(start_quiet_plies))
        final = quiet_after(befores.last, @moves.last, forward.last)
        if final != @quiet_plies
          raise InvalidPosition,
                "start_quiet_plies #{start_quiet_plies} and this history give #{final} quiet " \
                "plies, but quiet_plies was given as #{@quiet_plies}"
        end
        return forward
      end

      forward = counters_forward(befores, 0)
      return forward if quiet_after(befores.last, @moves.last, forward.last) == @quiet_plies

      counters_backward(befores)
    end

    def counters_forward(befores, first)
      quiet = first
      befores.each_with_index.map do |before, index|
        current = quiet
        quiet = quiet_after(before, @moves[index], quiet)
        current
      end
    end

    # Reached only when no move in the history resets the counter, so the value before move i
    # is the stored counter less the number of moves from i on. A negative value means the
    # stored counter contradicts the history: that entry is nil and undo refuses it.
    def counters_backward(befores)
      total = befores.length
      Array.new(total) do |index|
        quiet = @quiet_plies - (total - index)
        quiet.negative? ? nil : quiet
      end
    end

    def parse_history_move(text)
      text = text.to_s.strip
      squares = text.split(/[-x]/).map { |part| Integer(part) }
      raise InvalidPosition, "not a move: #{text.inspect}" if squares.length < 2

      captures = text.include?("x") ? squares.each_cons(2).map { |a, b| Square.midpoint(a, b) } : []
      Move.new(origin: squares.first, landings: squares[1..], captures: captures.compact)
    end

    def normalize_pending(path)
      path = Array(path).map { |square| Integer(square) }
      path.each { |square| Square.check_number(square) }
      path.freeze
    end

    # A capture or a man move resets the forty-move counter; a quiet king move increments it.
    # A promotion move is played by a man, so it resets the counter too.
    def quiet_after(before, move, quiet_plies)
      return 0 if move.capture? || !before.king_at?(move.origin)

      quiet_plies + 1
    end

    def record(move)
      before = @position
      @played << Played.new(move: move, position: before, quiet_plies: @quiet_plies)
      @moves << move
      @position = Rules.apply(before, move)
      @quiet_plies = quiet_after(before, move, @quiet_plies)
      @occurrences[@position.key] += 1
      @pending_path = nil
      check_terminal
      move
    end

    def check_terminal
      return if finished?

      side = side_to_move
      if @position.count(side).zero?
        finish(WINNER_RESULT.fetch(Side.opponent(side)), :no_pieces)
      elsif Rules.legal_moves(@position).empty?
        finish(WINNER_RESULT.fetch(Side.opponent(side)), :no_moves)
      elsif @occurrences[@position.key] >= REPETITION_LIMIT
        finish(:draw, :threefold_repetition)
      elsif @quiet_plies >= QUIET_PLY_LIMIT
        finish(:draw, :forty_move_rule)
      end
    end

    def finish(result, reason)
      @result = result
      @reason = reason
      @pending_path = nil
      self
    end
  end
end
