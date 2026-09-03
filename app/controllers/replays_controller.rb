# The replay: any match at any ply, as a page whose whole state is in its address.
#
#   GET /matches/12/replay          the starting position
#   GET /matches/12/replay?ply=7    the position after the seventh ply
#
# Three things are deliberate.
#
# It reads rows, not the engine. The position after every move was written by the engine when
# that move was played, so a replay is a lookup: the ply-th move row carries the board, and ply
# 0 is the position the match started from. Nothing here regenerates a move, restores a game or
# asks about legality, which is why an integration test can assert that Draughts::Game.restore
# is not called on this path.
#
# It never errors on a ply. A missing, empty, negative or non-numeric ply is the start, and a
# ply past the end is the final position. A link that was shared before three more moves were
# played still opens.
#
# It has the visibility of the match page and no controls at all: every square is a disabled
# button, so a replay cannot be used to play, and there is nothing here to authorise beyond
# being able to read the match, which anyone with the address can do (rubric 54).
class ReplaysController < ApplicationController
  include MatchScoped

  def show
    @rows = @match.moves.to_a
    @total = @rows.length
    @ply = clamped_ply
    @row = @ply.zero? ? nil : @rows[@ply - 1]
    @position = Draughts::Position.new(board_at_ply, side_to_move_at_ply)
    # The origin and the destination of the move that led here, tinted on the board exactly as
    # the match page tints the last move (rubric 39).
    @tinted = @row ? [ @row.origin, @row.landings.last ].compact : []
  end

  private
    # The ply this page shows: 0 to the number of moves. Anything else is clamped rather than
    # refused, and only a string of digits is a number at all ("3x", "-1" and "nine" are the
    # start, not an error).
    def clamped_ply
      wanted = params[:ply].to_s
      return 0 unless /\A\d+\z/.match?(wanted)

      wanted.to_i.clamp(0, @total)
    end

    def board_at_ply
      @row ? @row.position_after : @match.start_position
    end

    # Who is to move in the position on screen: the other side from the one that played this
    # ply, and at ply 0 whoever played the first move (or, in a match with no moves at all,
    # whoever is to move now, which is Red in every match this application creates).
    def side_to_move_at_ply
      side = @row ? @row.side_after : (@rows.first&.side || @match.side_to_move)
      Draughts::Side.cast(side)
    end
end
