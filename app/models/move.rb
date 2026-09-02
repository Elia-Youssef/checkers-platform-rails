# One completed move of a match.
#
# A whole jump sequence is one move and therefore one row: 24x15x8 stores origin 24, landings
# [15, 8] and captures [19, 11]. The row also carries the engine's position after the move,
# which is what lets Draughts::Game.restore rebuild the repetition counts without replaying
# the game and what phase 7 will replay from.
class Move < ApplicationRecord
  belongs_to :match, inverse_of: :moves

  serialize :landings, type: Array, coder: JSON
  serialize :captures, type: Array, coder: JSON

  validates :ply, numericality: { only_integer: true, greater_than: 0 },
    uniqueness: { scope: :match_id }
  validates :side, inclusion: { in: Match::SIDES }
  validates :pdn, presence: true
  validates :position_after, format: { with: Match::POSITION_FORMAT,
    message: "must be 32 characters over r, R, w, W and -" }
  validate :squares_are_pdn_numbers

  # The engine's value object for this row.
  def to_engine_move
    Draughts::Move.new(origin: origin, landings: landings, captures: captures,
                       promotion: promoted)
  end

  # The side to move after this move was played.
  def side_after
    Draughts::Side.opponent(Draughts::Side.cast(side)).to_s
  end

  def capture? = captures.present?

  private
    def squares_are_pdn_numbers
      squares = [ origin, *landings, *captures ]
      return if squares.all? { |square| Draughts::Square.number?(square) }

      errors.add(:base, "every square must be a PDN number 1 to 32")
    end
end
