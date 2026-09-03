# frozen_string_literal: true

module Draughts
  module AI
    # Negamax with alpha-beta pruning over Draughts::Position, at a fixed depth or by
    # iterative deepening against a clock.
    #
    # What the search knows and does not know
    #   It sees positions, never histories, so the two draw rules (threefold repetition and
    #   the forty-move rule) are invisible to it: a line that repeats scores like any other
    #   line. That is deliberate. The rules live in Draughts::Game, which is what actually
    #   plays the move, and giving the search a history would mean carrying the occurrence
    #   table down every branch for a rule it can barely act on inside eight plies. The
    #   visible consequence is the one CONCEPT.md 6.2 measured, a won king endgame drifting
    #   into a forty-move draw, which is what Evaluation's chase term is there to stop.
    #
    # Terminal positions
    #   The side to move having no legal move is a loss, and that is the only terminal the
    #   search scores. Having no pieces is a special case of it. A loss found n plies deeper
    #   scores n higher than one found further away (LOSS_SCORE minus the remaining depth,
    #   negated by the parent), so the search prefers a win in 2 to the same win in 6 and
    #   puts off a loss as long as it can.
    #
    # Move ordering
    #   Captures are mandatory across the whole side in English draughts, so a node's move
    #   list is either all captures or all quiet moves, and "captures first" is already true
    #   of every list Rules.legal_moves returns. What is left to order is the captures among
    #   themselves, biggest first, which is what order! does, plus the best move from the
    #   previous iteration or from the transposition table, which promote_first puts in
    #   front. Measured from the starting position, alpha-beta with that ordering grows by
    #   2.2 to 3.0 a ply (4527, 13192, 28798, 87082 nodes at depths 6 to 9) where the full
    #   tree grows by 4.7 to 5.0 (the published perft counts).
    #
    # Speed
    #   The search calls Rules.legal_moves and Rules.apply, the engine's unchecked fast
    #   path, never Draughts::Game: a Game would re-validate, copy a history and run the
    #   draw checks at every node. Measured in the development container, one node costs
    #   about 17 microseconds, 15 of them inside Rules.legal_moves, which is why the
    #   transposition table below is worth its complexity: over 24 sampled mid-game
    #   positions it took the worst iterative deepening to depth 8 from 3.33 s to 1.01 s.
    module Search
      # Bigger than any evaluation and any loss score, so it is a safe initial window.
      INFINITY = 1 << 30
      # The score of a position whose side to move has no legal move, before the
      # remaining-depth adjustment that prefers the quicker win.
      LOSS_SCORE = -100_000
      # Any score this big is a forced win or loss rather than a judgement of material.
      DECISIVE = 90_000

      # Thrown when a search runs past its hard deadline, caught by the iteration that set
      # it. TIMED_OUT is the value thrown, so a caught result is told apart by identity and
      # never mistaken for a legitimate return value.
      TIMEOUT = :draughts_ai_timeout
      TIMED_OUT = Object.new.freeze

      # Monotonic seconds. Every clock here is any object answering call; tests hand in a
      # fake one so a deadline can be crossed without waiting for it.
      DEFAULT_CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

      # Transposition table bounds. EXACT is the true value of the subtree at the depth it
      # was searched to, LOWER is a value the subtree is worth at least (it caused a beta
      # cutoff) and UPPER is a value it is worth at most (nothing beat alpha).
      EXACT = 0
      LOWER = 1
      UPPER = 2
      # A ceiling on the table so one long search cannot eat the process. It is a backstop
      # and nothing more. Measured on this build with a spy on every Run#store (the
      # session-2 audit's s2_budget.rb, re-run after the leaf change and reproducible to the
      # entry across runs): the starting position reaches depth 11, visits 173,679 nodes,
      # stores 73,693 times and ends with 58,839 distinct entries; the ten-king endgame that
      # finding H1 was about reaches depth 8, visits 155,835 nodes, stores 39,051 times and
      # ends with 21,214 entries. So the real worst case seen is about a ninth of this
      # number, and it scales with the depth an iteration reaches rather than with the clock.
      # The audit's pre-fix figures were half that, because the same 1.5 second budget now
      # buys a deeper iteration.
      TABLE_LIMIT = 500_000

      # How iterative deepening guesses what the next depth will cost: the ratio between the
      # last two iterations, clamped, and 3.0 before there are two to compare (measured from
      # the starting position, where the ratio runs 2.2 to 3.4). GROWTH_SAFETY is the margin
      # on that guess. Measured over fifteen positions with abort_after at 2.0 s: at 1.0 the
      # search averaged 1.18 s and abandoned one iteration to the deadline, at 1.35 it
      # averaged 0.85 s and abandoned none, and the mean depth fell only from 10.8 to 10.3.
      # Half a ply is a cheap price for a third off the time a player waits.
      FIRST_GROWTH = 3.0
      MIN_GROWTH = 1.5
      MAX_GROWTH = 8.0
      GROWTH_SAFETY = 1.35

      # What a root search found. move is the chosen move (uniform among the moves that tied
      # for the best score), score is that best score from the side to move's point of view,
      # depth is the depth actually completed, nodes counts every node visited including the
      # ones from shallower iterations, elapsed is measured on the clock that was handed in,
      # ties is how many moves shared the best score, complete is false when iterative
      # deepening abandoned an iteration to a deadline, and forced is true when there was
      # only ever one legal move to give back.
      Result = Data.define(:move, :score, :depth, :nodes, :elapsed, :ties, :complete,
                           :forced) do
        def complete?
          complete
        end

        # True when the side to move had exactly one legal move, so nothing was chosen.
        def forced?
          forced
        end
      end

      # The running state of one search: the node count, the clock, the deadline in force
      # and the transposition table. One instance lives for a whole iterative deepening
      # call, so nodes accumulate across iterations, the table survives from one depth to
      # the next (which is where most of its value is) and the deadline can be changed
      # between iterations.
      class Run
        attr_reader :nodes, :table, :exact_leaves
        attr_accessor :deadline

        def initialize(clock: DEFAULT_CLOCK, deadline: nil, table: false, exact_leaves: true)
          @clock = clock
          @deadline = deadline
          @table = table ? {} : nil
          @exact_leaves = exact_leaves
          @nodes = 0
        end

        def now
          @clock.call
        end

        # Counts a node and gives up on the whole search when the deadline has passed.
        # Measured cost of looking at the clock at every node while a deadline is live: 0.16
        # microseconds a node, 0.8 percent of a depth-8 search, against a node that costs
        # about 17 microseconds. Reading it every node rather than every 512th is what lets
        # a test with an injected clock cross a deadline at a node it can name.
        def tick
          @nodes += 1
          return if @deadline.nil?

          throw(TIMEOUT, TIMED_OUT) if @clock.call >= @deadline
        end

        # Remembers what a subtree was worth. Decisive scores are never stored: their value
        # counts the plies to the end of the game, which is only true at the depth they were
        # found, and a cached one probed from somewhere else would claim a win nearer than
        # it is.
        def store(position, depth, value, flag, move)
          return if @table.nil? || value.abs >= DECISIVE || @table.size >= TABLE_LIMIT

          @table[position] = [ depth, value, flag, move ]
        end
      end

      # One uniformly random move out of the ones handed in. Always draws exactly one number
      # from random, even when there is nothing to choose, so the stream a seed produces
      # depends only on how many times pick was called.
      def self.pick(moves, random)
        moves[random.rand(moves.length)]
      end

      # Sorts a node's moves in place, biggest capture first. Returns the same Array.
      #
      # The scan before the sort is not an optimisation for its own sake: most capture lists
      # are a single one-piece jump, and skipping the sort there keeps the node allocation
      # free. When it does sort it sorts stably (the index is part of the key), so equal
      # captures keep the generator's order and node counts stay reproducible.
      def self.order!(moves)
        return moves if moves.length < 2

        first = moves[0]
        return moves unless first.capture?

        count = first.captures.length
        index = 1
        length = moves.length
        while index < length
          break unless moves[index].captures.length == count

          index += 1
        end
        return moves if index == length

        moves.sort_by!.with_index { |move, at| [ -move.captures.length, at ] }
      end

      # The negamax value of a position for the side to move, searched to depth. The plain
      # scoring entry point: no move comes back, only the number.
      def self.score(position, depth:, clock: DEFAULT_CLOCK, deadline: nil, table: false,
                     exact_leaves: true)
        run = Run.new(clock: clock, deadline: deadline, table: table, exact_leaves: exact_leaves)
        negamax(run, position, depth, -INFINITY, INFINITY)
      end

      # A fixed-depth root search. Returns a Result, or nil when the side to move has no
      # legal move at all (a lost position, not a search failure).
      #
      # No transposition table by default: this is what Medium plays, and Medium is the
      # level TASK-BRIEF 1.4 pins as a plain fixed-depth-4 alpha-beta, cheap enough that the
      # table would cost more bookkeeping than it saves.
      def self.fixed(position, depth:, random: Random.new, clock: DEFAULT_CLOCK, table: false,
                     exact_leaves: true)
        run = Run.new(clock: clock, table: table, exact_leaves: exact_leaves)
        started = run.now
        outcome = root(run, position, depth, random)
        return nil if outcome.nil?

        Result.new(move: outcome[0], score: outcome[1], depth: depth, nodes: run.nodes,
                   elapsed: run.now - started, ties: outcome[2], complete: true,
                   forced: outcome[3] == 1)
      end

      # Iterative deepening. Searches depth 1, then 2, and so on:
      #
      #   floor          every depth up to and including this one is searched whatever the
      #                  clock says, so the reported depth is never below it, unless
      #                  hard_deadline is set and fires first
      #   budget         once floor has been passed, no new depth starts after this many
      #                  seconds of searching (TASK-BRIEF 1.4 pins this at 1.5 for Hard)
      #   abort_after    a hard stop above the floor: an iteration deeper than floor still
      #                  running after this many seconds is abandoned and its partial result
      #                  thrown away, and no iteration is started that the growth estimate
      #                  says would reach it
      #   hard_deadline  a hard stop that also applies at and below the floor, nil in this
      #                  method's own default and 2.5 seconds in what Draughts::AI passes;
      #                  see below
      #   cap            the deepest iteration that will ever be started
      #
      # Two things stop a deeper iteration, and both are needed. The budget is the rule the
      # brief pins. The estimate is what stops the search starting an iteration it will have
      # to throw away: with the budget alone, the starting position under YJIT came back
      # after the full 2.400 s reporting depth 9, having started a depth 10 and abandoned
      # it. With the estimate the same position comes back at 0.75 s with depth 10.
      # Declining to start a new depth is always allowed by the brief's rule, which says
      # only when a new depth may not start, and the depth floor is what guarantees the
      # search is never shallow.
      #
      # hard_deadline is the one thing here that can break the depth floor, so this method
      # leaves it nil and every caller decides. Draughts::AI passes it: HARD_DEADLINE is 2.5
      # seconds by the owner's decision of 2026-09-03, because TASK-BRIEF 1.4's "always
      # completing at least depth 8" and its 3.0 second request pin cannot both hold on every
      # legal position, and the request bound is the one that is kept. So the floor is
      # unconditional here only for a caller that passes hard_deadline: nil, and what the
      # application ships is the bounded answer: the deepest depth that did finish, reported
      # truthfully, with complete false. Depth 1 is never abandoned, so a move always comes
      # back.
      #
      # exact_leaves is false here and true for the fixed-depth search Medium uses: see
      # leaf_value for what the horizon gives up and what it buys.
      #
      # Returns a Result whose depth is the deepest iteration that finished, or nil when the
      # side to move has no legal move.
      def self.iterative(position, floor: 1, cap: 14, budget: 1.5, abort_after: nil,
                         hard_deadline: nil, random: Random.new, clock: DEFAULT_CLOCK,
                         table: true, exact_leaves: false)
        raise ArgumentError, "cap #{cap} is below floor #{floor}" if cap < floor

        run = Run.new(clock: clock, table: table, exact_leaves: exact_leaves)
        started = run.now
        depth = 1
        last = nil
        complete = true
        forced = false
        previous_seconds = nil
        growth = FIRST_GROWTH
        stop = [ abort_after, hard_deadline ].compact.min

        loop do
          run.deadline = iteration_deadline(started, depth, floor, abort_after, hard_deadline)
          iteration_started = run.now
          outcome = catch(TIMEOUT) { root(run, position, depth, random, last&.move) }
          if outcome.equal?(TIMED_OUT)
            complete = false
            break
          end
          break if outcome.nil?

          finished = run.now
          took = finished - iteration_started
          if previous_seconds&.positive?
            growth = (took / previous_seconds).clamp(MIN_GROWTH, MAX_GROWTH)
          end
          previous_seconds = took
          forced = outcome[3] == 1
          last = Result.new(move: outcome[0], score: outcome[1], depth: depth,
                            nodes: run.nodes, elapsed: finished - started, ties: outcome[2],
                            complete: true, forced: forced)

          break if depth >= cap
          if depth >= floor
            # Nothing to choose: searching deeper cannot change the answer, so stop as soon
            # as the floor has been honoured rather than spending the whole budget on it.
            break if forced

            elapsed = finished - started
            break if elapsed >= budget
            break if stop && elapsed + (took * growth * GROWTH_SAFETY) > stop
          end
          depth += 1
        end
        return nil if last.nil?

        last.with(nodes: run.nodes, elapsed: run.now - started, complete: complete,
                  forced: forced)
      end

      # The wall time at which the iteration about to run must give up, or nil.
      #
      # Depth 1 never has one: it costs a handful of nodes and it is what guarantees that a
      # move comes back at all. Above the floor, abort_after applies. At and below the
      # floor, only hard_deadline applies, and it is off only for a caller that passes nil,
      # which Draughts::AI does not.
      def self.iteration_deadline(started, depth, floor, abort_after, hard_deadline)
        return nil if depth <= 1

        limits = []
        limits << hard_deadline unless hard_deadline.nil?
        limits << abort_after if !abort_after.nil? && depth > floor
        return nil if limits.empty?

        started + limits.min
      end

      # The root: every legal move scored, the best score found, and one of the moves that
      # tied for it chosen uniformly at random. Returns [move, score, ties, width] or nil,
      # where width is how many legal moves there were in the first place.
      #
      # The window is (best - 1, INFINITY) rather than the full (-INFINITY, INFINITY) the
      # reference model uses per root move. Fail-soft negamax returns an exact value for
      # anything above alpha, so every move that ties with or beats the best so far still
      # comes back exact and the tie set is the set the full window would produce, while
      # everything worse is cut off early.
      #
      # The tie set is sorted by square path before the draw, so which move a seed picks
      # depends on the position and not on the order the search happened to try things in.
      def self.root(run, position, depth, random, first_move = nil)
        moves = Rules.legal_moves(position)
        return nil if moves.empty?

        order!(moves)
        promote_first(moves, first_move)

        best = -INFINITY
        ties = []
        moves.each do |move|
          value = -negamax(run, Rules.apply(position, move), depth - 1, -INFINITY, 1 - best)
          if value > best
            best = value
            ties.clear
            ties << move
          elsif value == best
            ties << move
          end
        end
        ties.sort_by!(&:squares)
        [ pick(ties, random), best, ties.length, moves.length ]
      end

      # The negamax value of a position for the side to move, with alpha-beta pruning.
      # Fail-soft: a value above alpha and below beta is exact, a value at or below alpha is
      # an upper bound, and a value at or above beta is a lower bound.
      #
      # The transposition table, when the run has one, is read under the standard rule that
      # only an exact entry may come back from inside the window: a lower bound returns only
      # when it already beats beta and an upper bound only when it is already at or under
      # alpha. That keeps the fail-soft contract the root depends on. The value an entry
      # carries may have been searched deeper than this node asked for, which is the usual
      # bargain: it makes the score a better one than a search to exactly this depth would
      # give, and it means the numbers here are not a pure fixed-depth minimax. Measured by
      # the session-2 audit against an unpruned negamax: a fixed-depth search with the table
      # on agreed on all 1,250 positions at depths 2 to 4, 150 at depth 5 and 40 at depth 6,
      # and the deviation appears only through iterative deepening, where an entry stored in
      # an earlier iteration carries a larger remaining depth than the current node asked
      # for: 1 of 200 positions at floor and cap 5, 1 of 40 at 6, and the chosen move was
      # never outside the true best set (0 of 240).
      def self.negamax(run, position, depth, alpha, beta)
        run.tick
        table = run.table
        entry = table && table[position]
        if entry && entry[0] >= depth
          value = entry[1]
          case entry[2]
          when EXACT then return value
          when LOWER then return value if value >= beta
          else return value if value <= alpha
          end
        end

        return leaf_value(position) if depth <= 0 && !run.exact_leaves

        moves = Rules.legal_moves(position)
        return LOSS_SCORE - depth if moves.empty?
        return Evaluation.evaluate(position) if depth <= 0

        order!(moves)
        promote_first(moves, entry[3]) if entry

        opening_alpha = alpha
        best = -INFINITY
        best_move = nil
        moves.each do |move|
          value = -negamax(run, Rules.apply(position, move), depth - 1, -beta, -alpha)
          if value > best
            best = value
            best_move = move
          end
          alpha = value if value > alpha
          break if alpha >= beta
        end

        if table
          flag = if best <= opening_alpha
            UPPER
          elsif best >= beta
            LOWER
          else
            EXACT
          end
          run.store(position, depth, best, flag, best_move)
        end
        best
      end

      # What a position at the search horizon is worth.
      #
      # Asking Rules.legal_moves here, only to find out whether the list is empty, is what a
      # deep search spends most of its time on: 70.5 percent of the 111,735 nodes of a
      # depth-8 search of the worst position the session-2 audit found were leaves, and 60.7
      # percent from the starting position. So the horizon asks the cheap half of the
      # question instead. A side with no pieces has certainly lost, and String#count answers
      # that in a fraction of a microsecond against the 15 microseconds a generation costs.
      #
      # What is given up is the other half: a side that still has pieces but whose every
      # piece is blocked is a loss too, and at the horizon that is now scored as material
      # rather than as a loss. Measured, that case is rare where it would matter: of the 13
      # terminal leaves in that depth-8 search, all 13 were "no pieces" and none was a
      # blockade, and the same search from the starting position has no terminal leaf at
      # all. Iterative deepening also repairs it: a blockade at exactly ply d is missed by
      # iteration d and seen by iteration d + 1, because at d + 1 it is an interior node,
      # where the full generation still runs and LOSS_SCORE - depth still applies.
      #
      # LOSS_SCORE is what LOSS_SCORE - depth gives at depth 0, so the two paths agree.
      def self.leaf_value(position)
        return LOSS_SCORE if position.count(position.side_to_move).zero?

        Evaluation.evaluate(position)
      end

      # Moves one move to the front of the list, leaving the rest in order. Iterative
      # deepening uses it for the previous iteration's answer and the search uses it for the
      # transposition table's best move, which is where most of the pruning comes from.
      def self.promote_first(moves, move)
        return moves if move.nil?

        at = moves.index(move)
        return moves if at.nil? || at.zero?

        moves.insert(0, moves.delete_at(at))
      end
    end
  end
end
