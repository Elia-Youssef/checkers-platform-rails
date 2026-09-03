# One persisted game of English draughts.
#
# The row is the whole truth: position, side to move, the pending jump path, the two draw
# counters and the completed moves. Every legality question is answered by rebuilding a
# Draughts::Game from those columns and rows (#game) and asking the engine, so the browser is
# never the authority and nothing about a match lives only in a server process.
#
# Seats. A seat is held by a signed-in User or by a browser's guest key, never by both. In a
# hot-seat match the creating identity holds both seats and everybody else is a viewer with a
# read-only board. In a match against the computer the human holds one seat and the other
# holds nobody: the computer is not an identity, it is the ai_level column, and #ai_side is
# simply the seat no one is sitting in. An online match seats a signed-in user in both
# colours: one at creation, the other when the invite link is used.
class Match < ApplicationRecord
  include MatchBroadcasts

  MODES = %w[ hotseat ai online ].freeze
  # waiting: an online match with a free seat. cancelled: a waiting match the creator gave up
  # on, kept as a row so the page can say so and the token can stay spent.
  STATUSES = %w[ waiting active finished cancelled ].freeze
  SIDES = %w[ red white ].freeze
  # The pinned names the engine uses, stored verbatim so Draughts::Game.restore accepts them.
  RESULTS = Draughts::Game::RESULTS.map(&:to_s).freeze
  REASONS = Draughts::Game::REASONS.map(&:to_s).freeze
  AI_LEVELS = %w[ easy medium hard ].freeze
  POSITION_FORMAT = Draughts::Position::BOARD_FORMAT
  # A PDN square as a form parameter: exactly one or two decimal digits, 1 to 32.
  SQUARE_FORMAT = /\A(?:[1-9]|[12][0-9]|3[0-2])\z/

  # The invite token. 24 random bytes is 32 URL-safe characters with no padding, comfortably
  # over the 20 the brief pins, and TOKEN_FORMAT is the alphabet urlsafe_base64 produces.
  # Both are checked by a validation, so a token that is short or oddly spelled cannot be
  # saved even if some later code writes the column itself.
  INVITE_TOKEN_BYTES = 24
  MINIMUM_TOKEN_LENGTH = 20
  TOKEN_FORMAT = /\A[A-Za-z0-9_-]+\z/

  # The DOM ids of the four fragments an accepted action re-renders. They are constants
  # because phase 6 broadcasts the same four fragments to every other browser watching the
  # match, and a broadcast naming a different id would silently update nothing.
  BOARD_ID = "match-board"
  STATUS_ID = "match-status"
  MOVES_ID = "match-moves"
  CONTROLS_ID = "match-controls"
  # The invite panel is a fifth fragment: it holds the token of a waiting online match, so it
  # is rendered for the creator alone and has to vanish from their page the moment somebody
  # joins, which a broadcast does by replacing it with an empty wrapper.
  INVITE_ID = "match-invite"

  has_many :moves, -> { order(:ply) }, dependent: :destroy, inverse_of: :match
  belongs_to :red_user, class_name: "User", optional: true
  belongs_to :white_user, class_name: "User", optional: true
  # The waiting match Play again created out of this finished one, so that the invite link
  # for the rematch can be shown to the opponent inside the match they are already looking at.
  belongs_to :rematch_match, class_name: "Match", optional: true

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
  validates :invite_token, uniqueness: true, allow_nil: true,
    length: { minimum: MINIMUM_TOKEN_LENGTH }, format: { with: TOKEN_FORMAT,
      message: "must be URL-safe: letters, digits, hyphen and underscore" }
  validate :seats_hold_one_identity_each
  validate :ai_level_belongs_to_a_computer_match
  validate :active_match_has_both_seats
  validate :finished_match_names_its_outcome
  validate :active_row_is_not_terminal
  validate :online_match_seats_users_only
  validate :waiting_and_cancelled_belong_to_online_play

  # A hot-seat match: one identity holds both seats, and it starts from the pinned opening
  # with Red to move.
  def self.open_hotseat(user: nil, guest_key: nil)
    raise ArgumentError, "a match needs a user or a guest key" if user.nil? && guest_key.blank?

    create!(mode: "hotseat", status: "active",
            red_user: user, white_user: user,
            red_guest_key: (guest_key if user.nil?),
            white_guest_key: (guest_key if user.nil?))
  end

  # A match against the computer. The human takes the seat of the colour they chose and the
  # other seat stays empty: what plays it is ai_level, so a match is never waiting for a
  # second player and no identity can ever be mistaken for the computer.
  #
  # It starts from the pinned opening with Red to move like every other match. When the human
  # chose White the caller plays the computer's first move (Red's) before showing the page, so
  # the match opens with a move already made; see #play_computer_reply!.
  def self.open_ai(side:, level:, user: nil, guest_key: nil)
    raise ArgumentError, "a match needs a user or a guest key" if user.nil? && guest_key.blank?
    raise ArgumentError, "not a colour: #{side.inspect}" unless SIDES.include?(side.to_s)

    human = side.to_s
    create!(mode: "ai", status: "active", ai_level: Draughts::AI.level(level).to_s,
            red_user: (user if human == "red"),
            white_user: (user if human == "white"),
            red_guest_key: (guest_key if user.nil? && human == "red"),
            white_guest_key: (guest_key if user.nil? && human == "white"))
  end

  # An online match: one signed-in user takes the colour they chose (or one at random) and
  # the other seat stays free until somebody uses the invite link. It is "waiting" until then,
  # which is what stops every action on it: the board is dead and the transitions all refuse.
  def self.open_online(creator:, colour:, random: Random.new)
    raise ArgumentError, "an online match needs a signed-in user" unless creator.is_a?(User)

    side = colour.to_s
    side = SIDES[random.rand(SIDES.length)] if side == "random"
    raise ArgumentError, "not a colour: #{colour.inspect}" unless SIDES.include?(side)

    create!(mode: "online", status: "waiting", invite_token: generate_invite_token,
            red_user: (creator if side == "red"),
            white_user: (creator if side == "white"))
  end

  # 32 URL-safe characters from SecureRandom, single use (see #join! and #cancel!).
  def self.generate_invite_token
    SecureRandom.urlsafe_base64(INVITE_TOKEN_BYTES)
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
  def cancelled? = status == "cancelled"
  def hotseat? = mode == "hotseat"
  def ai? = mode == "ai"
  def online? = mode == "online"

  # True while a jump sequence is part way through, which locks the board to the jumping
  # piece and takes Undo and Resign away until it ends.
  def sequence_pending? = pending_path.present?

  def can_undo?
    !online? && active? && !sequence_pending? && game.can_undo? && undo_ply_count.positive?
  end

  def can_resign? = active? && !sequence_pending?

  # ---- the invite link ------------------------------------------------------------------

  # True while this token can still take somebody to a free seat. The status alone would
  # answer it today, and invite_token_used_at is asked as well so that a link is dead from the
  # moment it was spent whatever happens to the row afterwards.
  def invite_open?
    waiting? && invite_token.present? && invite_token_used_at.nil? && free_seat.present?
  end

  # The colour nobody holds yet, or nil.
  def free_seat
    SIDES.find { |side| !seat_taken?(side) }
  end

  # The user in the first seat that is taken. On a waiting online match there is exactly one,
  # so this is the player who created it and is waiting to be joined.
  def creator
    SIDES.filter_map { |side| seat_user(side) }.first
  end

  # ---- draw offers ----------------------------------------------------------------------

  def draw_pending? = draw_offered_by.present?

  # True when this side may offer a draw right now: online, running, no jump part way
  # through and no offer already waiting for an answer.
  def can_offer_draw?(side)
    SIDES.include?(side.to_s) && draw_offer_refusal(side).nil?
  end

  # True when there is an offer for this side to answer, which is an offer the other side
  # made. The offering side sees that it is waiting instead.
  def draw_offer_for?(side)
    draw_pending? && SIDES.include?(side.to_s) && draw_offered_by != side.to_s
  end

  # True when this side is the one waiting for an answer.
  def draw_offered_by?(side)
    draw_pending? && draw_offered_by == side.to_s
  end

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
  # with. Against the computer that is the human's colour and the level, so the next game is
  # the same game again. Online it is the colour this player did not have, because a rematch
  # swaps them; who "this player" is has to be said, since an online match has two of them.
  # The keys are the names the create form posts, so Play again is that form submitted again.
  def play_again_params(user: nil)
    { mode: mode }.tap do |settings|
      if ai?
        settings[:colour] = human_side if human_side
        settings[:level] = ai_level if ai_level.present?
      elsif online?
        swapped = swapped_colour_for(user)
        settings[:colour] = swapped if swapped
      end
    end
  end

  # The colour this user did not play here, which is the colour they take in a rematch.
  def swapped_colour_for(user)
    return nil if user.nil?

    held = seats_held_by(user: user).first
    held && Draughts::Side.opponent(Draughts::Side.cast(held)).to_s
  end

  # ---- why an action cannot happen now -------------------------------------------------
  # One sentence per state, used by the transitions and by the resignation confirmation, so
  # the page and the endpoint never disagree and a waiting match is never told it has finished.

  def inactive_reason
    return nil if active?
    return "this match has already finished" if finished?
    return "this match was cancelled" if cancelled?

    "this match has not started yet"
  end

  # Why a resignation cannot be offered or accepted now, or nil.
  def resignation_refusal
    return inactive_reason unless active?
    return "a jump sequence is pending on square #{game.locked_square}" if sequence_pending?

    nil
  end

  # Why this side cannot offer a draw now, or nil. A jump part way through is refused for the
  # same reason a resignation is: the board is in the middle of one move.
  def draw_offer_refusal(side)
    return "a draw can only be offered in an online match" unless online?
    return inactive_reason unless active?
    return "a jump sequence is pending on square #{game.locked_square}" if sequence_pending?
    return "a draw offer is already waiting for an answer" if draw_pending?

    nil
  end

  # Why this side cannot answer a draw offer now, or nil.
  def draw_answer_refusal(side)
    return "a draw can only be offered in an online match" unless online?
    return inactive_reason unless active?
    return "there is no draw offer to answer" unless draw_pending?
    return "you offered this draw: only your opponent can answer it" if draw_offered_by?(side)

    nil
  end

  # Why this match cannot be joined by this user now, or nil. This is the whole single-use rule
  # and the only place it is decided: #join! asks it again inside its own transaction, so the
  # answer is the answer for the row as it stands at the moment of the write.
  #
  # Every status but waiting refuses, and each one says which. This deliberately does not reuse
  # inactive_reason: that helper answers "why can nothing happen here", and its nil for an
  # active match is right for a move or a resignation and exactly wrong for a join, which is a
  # match that is already running. Answering nil there let a second visitor be written into a
  # taken seat (session-6 audit, finding C1).
  def join_refusal(user)
    return "this is not an online match" unless online?
    return "this match has already started" if active?
    return "this match has already finished" if finished?
    return "this match was cancelled" if cancelled?
    return "this match cannot be joined" unless waiting?
    return "the invite link has already been used" if invite_token_used_at.present?
    return "you are already playing in this match" if user && seats_held_by(user: user).any?
    return "both seats are taken" if free_seat.nil?

    nil
  end

  def cancellation_refusal
    return "this is not an online match" unless online?
    return "this match has already started" if active?
    return inactive_reason unless waiting?

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

  # True when a page showing these seats may offer moves: the match is running and one of
  # them is the seat of the side to move. In hot-seat one browser holds both, so it is the
  # side to move that decides; online it is also the seat, which is what keeps White's board
  # dead while Red thinks. This is the rendering half of MatchScoped's rule, and the server
  # refuses anything a page offers wrongly.
  def playable_by?(seats)
    active? && Array(seats).map(&:to_s).include?(side_to_move)
  end

  def viewer?(user: nil, guest_key: nil)
    seats_held_by(user: user, guest_key: guest_key).empty?
  end

  # The name shown for a seat: a user's display name, "Guest" for an unregistered player,
  # "Computer (Hard)" for the seat the computer plays.
  def seat_name(side)
    return computer_name if ai? && side.to_s == ai_side

    seat_user(side)&.display_name || (seat_guest_key(side).present? ? "Guest" : "Open seat")
  end

  # ---- the computer -------------------------------------------------------------------

  # The side the computer plays: the seat nobody is sitting in. nil unless this is a match
  # against the computer with exactly one seat taken.
  def ai_side
    return nil unless ai?

    empty = SIDES.reject { |side| seat_taken?(side) }
    empty.length == 1 ? empty.first : nil
  end

  # The side the person plays, the other half of the same question.
  def human_side
    return nil unless ai?

    taken = SIDES.select { |side| seat_taken?(side) }
    taken.length == 1 ? taken.first : nil
  end

  # "Computer (Hard)": the seat's name, and how the level reaches the page and the log.
  def computer_name
    ai_level.present? ? "Computer (#{Draughts::AI.label(ai_level)})" : "Computer"
  end

  # True while it is the computer's turn. This is a transient state: the reply is played
  # inside the same request that recorded the human's move, so a match at rest never shows
  # it. While it is true the human does not hold the acting seat, so the seat rule refuses a
  # move from them (403) without any extra check.
  def computer_to_move?
    ai? && active? && side_to_move == ai_side
  end

  # The last move row the computer played and searched, or nil. The status panel reads the
  # depth and the time off it, so the sentence survives a reload and a restart.
  def last_computer_move
    return nil unless ai?

    last = move_rows.last
    last if last && last.side == ai_side && !last.ai_depth.nil?
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
    # Every leg is broadcast, not only a completed move: the opponent and any viewer watch a
    # jump sequence happen square by square, exactly as the player making it does.
    broadcast_state!
    leg
  end

  # Takes back the last completed move, or, against the computer, the human's last move
  # together with the computer's reply: two plies in one transaction, so the board comes back
  # to the position the human was looking at rather than to the computer's turn.
  #
  # Refused online, while a jump sequence is pending, once the match has finished, and, in a
  # match the human plays as White, when the only move on the board is the computer's opening
  # move as Red: there is no move of the human's to take back yet.
  def undo_last_move!
    undone = []
    write do
      # The state of the match first, so a waiting or finished match is told what it is
      # whatever mode it is in; the online rule only matters for a match that is running.
      raise Draughts::IllegalMove, inactive_reason unless active?
      raise Draughts::IllegalMove, "undo is not available in an online match" if online?
      if sequence_pending?
        raise Draughts::IllegalMove, "a jump sequence is pending on square #{game.locked_square}"
      end

      wanted = undo_ply_count
      if wanted.zero?
        raise Draughts::IllegalMove,
              "the computer's opening move cannot be taken back: play a move of your own first"
      end

      current = game
      wanted.times do
        undone << current.undo
        moves.order(:ply).last!.destroy!
        moves.reset
      end
      write_state_from(current)
    end
    broadcast_state!
    undone.first
  end

  # How many plies one Undo takes back from the row as it now stands: one in hot-seat, and
  # against the computer as many as it takes to unplay the human's last move, which is two
  # when the computer has replied and one when it has not (a reply the race check discarded,
  # so the board is left showing the computer's turn and Undo is the way back).
  #
  # Zero means one specific thing: the last move is the computer's and there is no move of the
  # human's under it, which is the opening move of a game the human plays as White. A match
  # with no moves at all answers 1, not 0, so that the engine refuses it in the words it uses
  # everywhere else ("there is no move to undo") instead of being told about an opening move
  # that was never played.
  def undo_ply_count
    return 1 unless ai?

    rows = move_rows
    return 1 unless rows.last&.side == ai_side

    rows.length >= 2 ? 2 : 0
  end

  # Plays the computer's move and stores it as one row, whether it is one leg or a whole jump
  # sequence. Returns the Draughts::AI::Choice, or nil when there was nothing to play.
  #
  # The search runs outside the transaction on purpose. It can take two seconds at Hard, and
  # Rails opens SQLite transactions as BEGIN IMMEDIATE, so searching inside one would lock
  # every other writer out of the whole database for that long. The row is therefore read,
  # released, searched against, and then re-read inside the transaction that writes: if
  # anything moved in between (another request already played this reply, an undo took the
  # position back, the match ended), the position and the ply count no longer match the ones
  # the move was computed for and the reply is dropped rather than applied to a board it was
  # never legal on. Draughts::Game#play validates it against the position a second time in any
  # case, so the engine, not this method, is the last word on legality.
  def play_computer_reply!
    return nil unless computer_to_move? && !sequence_pending?

    searched = game
    key = searched.position.key
    plies = searched.plies
    choice = Draughts::AI.choose(searched, level: ai_level, random: self.class.ai_random(plies))

    applied = false
    write do
      if computer_to_move? && !sequence_pending? &&
         game.position.key == key && game.plies == plies
        record_computer_move(game, choice)
        applied = true
      end
    end

    if applied
      Rails.logger.info("[Match #{id}] computer move: #{choice.summary}")
      broadcast_state!
      choice
    else
      Rails.logger.info(
        "[Match #{id}] computer move discarded, the match moved on during the search: #{choice.summary}")
      nil
    end
  rescue Draughts::Error, ActiveRecord::ActiveRecordError => e
    # A reply that cannot be played must not become a refusal of the human's move, which the
    # row has already accepted, so it is logged and dropped and nil comes back. The row is
    # then left on the computer's turn, which the controls partial explains and Undo undoes.
    # Nothing reachable raises here: the engine was asked about the very position it then
    # played on, and the save is the same one every other transition makes. Anything that is
    # not one of these two families is a programming error and is left to raise.
    Rails.logger.error("[Match #{id}] the computer could not reply: #{e.class}: #{e.message}")
    nil
  end

  # The random source for one computer move. A fresh Random every time in development and in
  # production, so games vary as TASK-BRIEF 1.4 requires; a seeded one when
  # config.x.ai_random_seed holds an integer, which is how the tests get the same game twice.
  # The ply goes into the seed so a seeded game is still a varied game and not one move
  # repeated whenever a position recurs.
  #
  # An unset config.x key answers with an empty ActiveSupport::OrderedOptions, not with nil,
  # so the seed is read through Integer() and anything that is not a number means "no seed".
  def self.ai_random(ply = 0)
    seed = Integer(Rails.configuration.x.ai_random_seed)
    Random.new(seed + ply)
  rescue TypeError, ArgumentError
    Random.new
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
    broadcast_state!
    self
  end

  # ---- online transitions ----------------------------------------------------------------

  # Takes the free seat and starts the match. Asking whether the link is still open, taking the
  # seat, marking the token spent and activating the match are one transaction on a row that was
  # re-read and locked inside it (see #write), so two people opening the same link at the same
  # moment cannot both be seated: Rails opens every SQLite transaction as BEGIN IMMEDIATE, which
  # takes the database write lock before the re-read, so the second one begins only after the
  # first has committed and then finds the match active and is refused. Nothing outside this
  # method decides it; the controller reports whatever answer comes back.
  #
  # broadcast: false is for a caller that is itself inside a transaction (start_rematch!) and
  # will broadcast once its own work has committed. Nothing is ever broadcast for a write that
  # could still roll back.
  def join!(user, broadcast: true)
    raise ArgumentError, "an online seat needs a signed-in user" unless user.is_a?(User)

    write do
      refusal = join_refusal(user)
      raise Draughts::IllegalMove, refusal if refusal

      side = free_seat
      assign_attributes(status: "active", invite_token_used_at: Time.current)
      side == "red" ? self.red_user = user : self.white_user = user
      save!
    end
    broadcast_state! if broadcast
    self
  end

  # The creator gives up on a waiting match. The row stays, so the page can say what happened
  # and the token stays spent for good.
  def cancel!
    write do
      refusal = cancellation_refusal
      raise Draughts::IllegalMove, refusal if refusal

      update!(status: "cancelled", invite_token_used_at: Time.current)
    end
    broadcast_state!
    self
  end

  # Offers a draw on behalf of one seat. One offer at a time; any completed move clears it
  # (write_state_from does that for every move, undo and resignation).
  def offer_draw!(side)
    side = checked_side(side)
    write do
      refusal = draw_offer_refusal(side)
      raise Draughts::IllegalMove, refusal if refusal

      update!(draw_offered_by: side)
    end
    broadcast_state!
    self
  end

  # Answers the pending offer for the other seat: accepting ends the match as a draw by
  # agreement, declining clears the offer and play goes on.
  def answer_draw!(side, accept:)
    side = checked_side(side)
    write do
      refusal = draw_answer_refusal(side)
      raise Draughts::IllegalMove, refusal if refusal

      if accept
        current = game
        current.agree_draw
        write_state_from(current)
      else
        update!(draw_offered_by: nil)
      end
    end
    broadcast_state!
    self
  end

  # Play again on a finished online match. The new match is a waiting online match with the
  # colours swapped and this user seated; the finished match keeps a pointer to it, which is
  # how the invite link reaches the opponent (the finished match broadcasts, and the link
  # travels only on the opponent's own seat stream, never to a viewer).
  #
  # When the opponent presses Play again second they do not create a third match: the rematch
  # already recorded here is still waiting, so they take its free seat and both players end up
  # in the same game.
  def start_rematch!(user:)
    raise ArgumentError, "a rematch needs a signed-in user" unless user.is_a?(User)

    target = nil
    created = false
    joined = false
    # One transaction on the locked row, like every other transition here. Deciding whether a
    # rematch exists and creating one used to happen outside a transaction, so both players
    # pressing Play again at the same moment each created one and one was orphaned with a live
    # invite token (session-6 audit, finding H1). Now the second press begins only after the
    # first has committed, sees rematch_match_id and takes its free seat instead.
    write do
      raise Draughts::IllegalMove, "a rematch belongs to an online match" unless online?
      raise Draughts::IllegalMove, "this match has not finished yet" unless finished?
      raise Draughts::IllegalMove, "you are not playing in this match" if seats_held_by(user: user).empty?

      target = rematch_match
      # A rematch that is waiting or running is the rematch: pressing Play again a second time,
      # or pressing it as the opponent, goes there rather than starting a third game. Anything
      # else is spent, and the pointer is replaced. Without that last part, cancelling a rematch
      # turned Play again into a dead end: it kept answering with the cancelled row, for both
      # players, for good (session-6 diff review, regression R1).
      target = nil unless target.nil? || target.waiting? || target.active?

      if target.nil?
        settings = play_again_params(user: user)
        target = self.class.open_online(creator: user, colour: settings.fetch(:colour))
        update!(rematch_match: target)
        created = true
      elsif target.join_refusal(user).nil?
        # The opponent pressed Play again second: they take the seat in the match that already
        # exists rather than starting a third one.
        target.join!(user, broadcast: false)
        joined = true
      end
    end

    # Only once both writes have committed: the finished match now points at a rematch, and the
    # rematch itself may have just gone active.
    broadcast_state! if created
    target.broadcast_state! if joined
    target
  end

  private
    def checked_side(side)
      side = side.to_s
      raise ArgumentError, "not a colour: #{side.inspect}" unless SIDES.include?(side)

      side
    end

    # The computer's chosen move applied to the reloaded game and written as one row, jump
    # sequence and all. Draughts::Game#play refuses anything the position does not allow, so
    # a move computed against a stale board cannot be stored even if the checks above missed.
    def record_computer_move(current, choice)
      move = current.play(choice.move)
      moves.create!(ply: current.plies, side: ai_side, pdn: move.pdn,
                    origin: move.origin, landings: move.landings,
                    captures: move.captures, promoted: move.promotion?,
                    position_after: current.position.board_string,
                    ai_depth: choice.depth, ai_nodes: choice.nodes,
                    ai_elapsed_ms: (choice.elapsed * 1000).round)
      write_state_from(current)
    end

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
        # Re-read the row inside the transaction, taking a row lock where the database offers
        # one. On SQLite (every environment here) Arel drops the FOR UPDATE clause and the
        # serialization comes from the transaction itself: Rails opens SQLite transactions with
        # BEGIN IMMEDIATE, so the write lock is held from before this read until the commit, and
        # a second writer waits (timeout 5000 ms in config/database.yml) rather than interleaving.
        lock!
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

    # An active match needs somebody in every seat a person plays. Against the computer that
    # is one seat: the other is deliberately empty, because ai_level plays it, and a seat that
    # held both an identity and the computer would make "who may act here" ambiguous.
    def active_match_has_both_seats
      return unless status == "active"

      if ai?
        errors.add(:base, "a match against the computer needs a player in one seat") if human_side.nil?
      else
        SIDES.each do |side|
          errors.add(:base, "an active match needs a player in the #{side} seat") unless seat_taken?(side)
        end
      end
    end

    # ai_level is what plays the empty seat, so an ai match without one has no opponent, and a
    # level on a match nobody plays the computer in would name an opponent that is not there.
    def ai_level_belongs_to_a_computer_match
      if ai? && ai_level.blank?
        errors.add(:ai_level, "is required in a match against the computer")
      elsif !ai? && ai_level.present?
        errors.add(:ai_level, "belongs only to a match against the computer")
      end
    end

    # TASK-BRIEF 1.5: online matches require a signed-in user in both seats, so a guest key
    # may not hold one even for a moment, and an online match always carries its invite token.
    def online_match_seats_users_only
      return unless online?

      SIDES.each do |side|
        next if seat_guest_key(side).blank?

        errors.add(:base, "an online match seats signed-in players only, not a guest")
      end
      errors.add(:invite_token, "is required for an online match") if invite_token.blank?
    end

    # Only an online match ever waits for a second player, and only a waiting one can be
    # cancelled; a hot-seat or computer match is playable the moment it exists.
    def waiting_and_cancelled_belong_to_online_play
      return if online?
      return unless %w[ waiting cancelled ].include?(status)

      errors.add(:status, "cannot be #{status} outside an online match")
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
