# One persisted game of English draughts.
#
# The row is the whole truth: position, side to move, the pending jump path, the two draw
# counters and the completed moves. Every legality question is answered by rebuilding a
# Draughts::Game from those columns and rows (#game) and asking the engine, so the browser is
# never the authority and nothing about a match lives only in a server process.
#
# Seats. A seat is held by a signed-in User or by a browser's guest key, never by both. In a
# hot-seat match the creating identity holds both seats and everybody else is a viewer with a
# read-only board.
class Match < ApplicationRecord
  MODES = %w[ hotseat ai online ].freeze
  STATUSES = %w[ waiting active finished ].freeze
  SIDES = %w[ red white ].freeze
  # The pinned names the engine uses, stored verbatim so Draughts::Game.restore accepts them.
  RESULTS = Draughts::Game::RESULTS.map(&:to_s).freeze
  REASONS = Draughts::Game::REASONS.map(&:to_s).freeze
  AI_LEVELS = %w[ easy medium hard ].freeze
  POSITION_FORMAT = Draughts::Position::BOARD_FORMAT
  # A PDN square as a form parameter: exactly one or two decimal digits, 1 to 32.
  SQUARE_FORMAT = /\A(?:[1-9]|[12][0-9]|3[0-2])\z/

  # The DOM ids of the four fragments an accepted action re-renders. They are constants
  # because phase 6 broadcasts the same four fragments to every other browser watching the
  # match, and a broadcast naming a different id would silently update nothing.
  BOARD_ID = "match-board"
  STATUS_ID = "match-status"
  MOVES_ID = "match-moves"
  CONTROLS_ID = "match-controls"

  has_many :moves, -> { order(:ply) }, dependent: :destroy, inverse_of: :match
  belongs_to :red_user, class_name: "User", optional: true
  belongs_to :white_user, class_name: "User", optional: true

  serialize :pending_path, type: Array, coder: JSON

  attribute :start_position, :string, default: -> { Draughts::Position::START_BOARD }
  attribute :position, :string, default: -> { Draughts::Position::START_BOARD }

  validates :mode, inclusion: { in: MODES }
  validates :status, inclusion: { in: STATUSES }
  validates :side_to_move, inclusion: { in: SIDES }
  validates :start_position, :position, format: { with: POSITION_FORMAT,
    message: "must be 32 characters over r, R, w, W and -" }
  validates :quiet_plies, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :result, inclusion: { in: RESULTS }, allow_nil: true
  validates :reason, inclusion: { in: REASONS }, allow_nil: true
  validates :ai_level, inclusion: { in: AI_LEVELS }, allow_nil: true
  validates :draw_offered_by, inclusion: { in: SIDES }, allow_nil: true
  validates :invite_token, uniqueness: true, allow_nil: true
  validate :seats_hold_one_identity_each
  validate :active_match_has_both_seats
  validate :finished_match_names_its_outcome
  validate :active_row_is_not_terminal

  # A hot-seat match: one identity holds both seats, and it starts from the pinned opening
  # with Red to move.
  def self.open_hotseat(user: nil, guest_key: nil)
    raise ArgumentError, "a match needs a user or a guest key" if user.nil? && guest_key.blank?

    create!(mode: "hotseat", status: "active",
            red_user: user, white_user: user,
            red_guest_key: (guest_key if user.nil?),
            white_guest_key: (guest_key if user.nil?))
  end

  # A square number 1 to 32 out of a form parameter, or Draughts::InvalidPosition.
  #
  # The regular expression is the whole rule: one or two decimal digits naming a square in
  # 1 to 32, no sign, no leading zero, no underscore, no surrounding whitespace and no other
  # base. Integer(value) was used here and accepts 0x0b, 013, 0b1011, 1_1, +11 and " 11 " as
  # eleven, all of which reached the engine as a legal move. Nothing a form or a link this
  # application renders can produce any of those spellings, so they are refused.
  def self.square_number(value)
    text = value.to_s
    raise Draughts::InvalidPosition, "not a square number: #{value.inspect}" unless SQUARE_FORMAT.match?(text)

    Draughts::Square.check_number(text.to_i)
  end

  # ---- the engine ---------------------------------------------------------------------

  # The Draughts::Game this row describes, rebuilt from the stored columns and every move row
  # from the start of the match, which is what makes the quiet-ply counter and the repetition
  # counts recoverable (see the engine's Game.restore).
  def game
    @game ||= restored_game.tap { |restored| heal_terminal_row(restored) }
  end

  def reload(...)
    @game = nil
    super
  end

  def active? = status == "active"
  def waiting? = status == "waiting"
  def finished? = status == "finished"
  def hotseat? = mode == "hotseat"
  def ai? = mode == "ai"
  def online? = mode == "online"

  # True while a jump sequence is part way through, which locks the board to the jumping
  # piece and takes Undo and Resign away until it ends.
  def sequence_pending? = pending_path.present?

  def can_undo?
    !online? && active? && !sequence_pending? && game.can_undo?
  end

  def can_resign? = active? && !sequence_pending?

  # ---- how this match is named and repeated -------------------------------------------
  # Both are derived from the row so that phases 5 and 6 plug their modes in here and the
  # views do not change.

  # The page heading and the browser title.
  def heading
    case mode
    when "hotseat" then "Hot-seat match"
    when "ai" then [ "Match against the computer", ("(#{ai_level.capitalize})" if ai_level.present?) ].compact.join(" ")
    when "online" then "Online match"
    else "Match"
    end
  end

  # The settings Play again carries: the same mode, and whatever else that mode is played
  # with. Phase 5 adds the human's colour beside the level here; phase 6 will want the colours
  # swapped, which is the same one place.
  def play_again_params
    { mode: mode }.tap do |settings|
      settings[:ai_level] = ai_level if ai? && ai_level.present?
    end
  end

  # ---- why an action cannot happen now -------------------------------------------------
  # One sentence per state, used by the transitions and by the resignation confirmation, so
  # the page and the endpoint never disagree and a waiting match is never told it has finished.

  def inactive_reason
    return nil if active?

    finished? ? "this match has already finished" : "this match has not started yet"
  end

  # Why a resignation cannot be offered or accepted now, or nil.
  def resignation_refusal
    return inactive_reason unless active?
    return "a jump sequence is pending on square #{game.locked_square}" if sequence_pending?

    nil
  end

  # ---- seats --------------------------------------------------------------------------

  def seat_user(side) = side.to_s == "red" ? red_user : white_user
  def seat_guest_key(side) = side.to_s == "red" ? red_guest_key : white_guest_key
  def seat_taken?(side) = seat_user(side).present? || seat_guest_key(side).present?

  # True when this identity holds this seat. A guest key is a bearer secret from a signed
  # cookie, so it is compared in constant time.
  def seat_held_by?(side, user: nil, guest_key: nil)
    if (seated = seat_user(side))
      user.present? && seated.id == user.id
    elsif (key = seat_guest_key(side)).present?
      guest_key.present? && ActiveSupport::SecurityUtils.secure_compare(key, guest_key.to_s)
    else
      false
    end
  end

  # The sides this identity may act for: both in a hot-seat match it created, one online,
  # none for a viewer.
  def seats_held_by(user: nil, guest_key: nil)
    SIDES.select { |side| seat_held_by?(side, user: user, guest_key: guest_key) }
  end

  def viewer?(user: nil, guest_key: nil)
    seats_held_by(user: user, guest_key: guest_key).empty?
  end

  # The name shown for a seat: a user's display name, "Guest" for an unregistered player.
  def seat_name(side)
    seat_user(side)&.display_name || (seat_guest_key(side).present? ? "Guest" : "Open seat")
  end

  # ---- transitions --------------------------------------------------------------------
  # Each one runs inside a transaction that begins by reloading the row, asks the engine what
  # is legal now, and writes only what the engine accepted. So a refusal leaves the row exactly
  # as it was, and a request that was composed against a board another request has already
  # moved on is decided against the board as it now stands, not against what the browser saw.
  # Rails opens SQLite transactions as BEGIN IMMEDIATE, which serializes writers, so the read
  # and the write inside one of these blocks cannot be interleaved with another writer.
  #
  # Every refusal is a Draughts::IllegalMove, which the controllers answer with 422.

  # Plays one leg of a move: one click. Returns the engine's LegResult, which says whether the
  # jump sequence is now complete. A completed sequence writes one moves row.
  def play_leg!(from, to)
    from = self.class.square_number(from)
    to = self.class.square_number(to)

    leg = nil
    write do
      raise Draughts::IllegalMove, inactive_reason unless active?

      mover = side_to_move
      current = game
      leg = current.play_leg(from, to)

      if leg.complete?
        moves.create!(ply: current.plies, side: mover, pdn: leg.move.pdn,
                      origin: leg.move.origin, landings: leg.move.landings,
                      captures: leg.move.captures, promoted: leg.move.promotion?,
                      position_after: current.position.board_string)
        write_state_from(current)
      else
        update!(pending_path: current.pending_path)
      end
    end
    leg
  end

  # Takes back the last completed move. Hot-seat only in this phase; refused online, while a
  # jump sequence is pending and once the match has finished (the engine refuses the last two
  # itself, and this adds the online rule the engine cannot know about).
  def undo_last_move!
    undone = nil
    write do
      # The state of the match first, so a waiting or finished match is told what it is
      # whatever mode it is in; the online rule only matters for a match that is running.
      raise Draughts::IllegalMove, inactive_reason unless active?
      raise Draughts::IllegalMove, "undo is not available in an online match" if online?
      if sequence_pending?
        raise Draughts::IllegalMove, "a jump sequence is pending on square #{game.locked_square}"
      end

      current = game
      undone = current.undo
      moves.order(:ply).last!.destroy!
      moves.reset
      write_state_from(current)
    end
    undone
  end

  # Ends the match as a win for the other side. side is the side that resigns: in hot-seat
  # that is the side to move.
  def resign!(side)
    write do
      refusal = resignation_refusal
      raise Draughts::IllegalMove, refusal if refusal

      current = game
      current.resign(Draughts::Side.cast(side))
      write_state_from(current)
    end
    self
  end

  private
    def restored_game
      Draughts::Game.restore(
        position: position, side: side_to_move, quiet_plies: quiet_plies,
        moves: move_rows.map(&:to_engine_move), positions: position_keys,
        pending_path: pending_path.presence, result: result, reason: reason)
    end

    # A row that says active over a position the engine calls finished can never be closed:
    # the status line and the controls read the column and offer play, the board reads the
    # engine and is entirely dead, and every action is refused because the engine has already
    # ended the game. No transition here can write such a row (write_state_from always stores
    # the status the engine reported) and active_row_is_not_terminal refuses to save one, but a
    # seed, a console session or a future phase writing a position directly could. When one
    # turns up, close it from the engine's own verdict rather than rendering the contradiction,
    # and say so in the log. update_columns, so this cannot re-enter validation or #game.
    def heal_terminal_row(restored)
      return unless persisted? && status == "active" && restored.finished?

      transaction do
        update_columns(result: restored.result.to_s, reason: restored.reason.to_s,
                       status: "finished", updated_at: Time.current)
      end
      Rails.logger.warn(
        "[Match #{id}] was stored active at a terminal position; healed to finished "         "#{restored.result}/#{restored.reason} from the engine")
    end

    # One transition: reload inside the transaction so the engine is asked about the row as it
    # stands, run the block, and leave no memoized game behind whether it committed or rolled
    # back. A write the database refuses becomes a refusal too, carrying its reason, rather
    # than a 500.
    def write
      transaction do
        reload
        yield
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      raise Draughts::IllegalMove, "this match has moved on since that click: #{e.message}"
    ensure
      reset_game
    end

    # The association without a database round trip once it is loaded, ordered by ply.
    def move_rows
      moves.loaded? ? moves.to_a : moves.order(:ply).to_a
    end

    # Every position this match has held, oldest first: the start followed by the position
    # after each move. The engine counts occurrences over this list for the threefold rule,
    # so it must end with the current position.
    def position_keys
      rows = move_rows
      first_side = Draughts::Side.cast(rows.first&.side || side_to_move)
      keys = [ Draughts::Position.new(start_position, first_side).key ]
      rows.each do |row|
        played_by = Draughts::Side.cast(row.side)
        keys << Draughts::Position.new(row.position_after, Draughts::Side.opponent(played_by)).key
      end
      keys
    end

    def write_state_from(current)
      update!(position: current.position.board_string,
              side_to_move: current.side_to_move.to_s,
              quiet_plies: current.quiet_plies,
              pending_path: current.pending_path || [],
              result: current.result&.to_s,
              reason: current.reason&.to_s,
              status: current.finished? ? "finished" : "active",
              draw_offered_by: nil)
    end

    def reset_game
      @game = nil
    end

    def seats_hold_one_identity_each
      SIDES.each do |side|
        next unless seat_user(side).present? && seat_guest_key(side).present?

        errors.add(:base, "the #{side} seat cannot be held by a user and a guest at once")
      end
    end

    def active_match_has_both_seats
      return unless status == "active"

      SIDES.each do |side|
        errors.add(:base, "an active match needs a player in the #{side} seat") unless seat_taken?(side)
      end
    end

    def finished_match_names_its_outcome
      return unless status == "finished"

      errors.add(:result, "is required once a match has finished") if result.blank?
      errors.add(:reason, "is required once a match has finished") if reason.blank?
    end

    # An active row whose position is already lost is unplayable and unfinishable, so it may
    # not be saved. This asks the engine about the position alone, which settles the two
    # terminal conditions that a position carries by itself (no pieces, no legal move). The two
    # draw rules depend on the history rather than the position and are settled by
    # write_state_from, which stores whatever result the engine reported after a move.
    def active_row_is_not_terminal
      return unless status == "active"
      return unless POSITION_FORMAT.match?(position.to_s) && SIDES.include?(side_to_move)

      side = Draughts::Side.cast(side_to_move)
      current = Draughts::Position.new(position, side)
      return unless current.count(side).zero? || Draughts::Rules.legal_moves(current).empty?

      errors.add(:status, "cannot be active: #{side_to_move.capitalize} has already lost this position")
    end
end
