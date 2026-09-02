class CreateMatches < ActiveRecord::Migration[8.1]
  def change
    create_table :matches do |t|
      # hotseat, ai or online. Only hotseat is playable in this phase; the other two are
      # pinned here so the column and its validation do not move under later phases.
      t.string :mode, null: false
      # waiting (an online match with a free seat), active, finished.
      t.string :status, null: false, default: "active"

      # A seat is held by a signed-in user or by a browser's guest key, never by both.
      t.references :red_user, foreign_key: { to_table: :users }
      t.references :white_user, foreign_key: { to_table: :users }
      t.string :red_guest_key
      t.string :white_guest_key

      # The position this match started from, and the position now: both the engine's
      # 32-character string over PDN squares 1 to 32. Storing the start as well as the
      # current position is what makes Draughts::Game.restore exact for a match that did
      # not begin at the standard opening (the draw-rule tests and, later, replay).
      t.string :start_position, null: false
      t.string :position, null: false
      t.string :side_to_move, null: false, default: "red"

      # Origin plus the landing squares of the legs played so far, as a JSON array. NULL
      # unless a jump sequence is part way through: Active Record's serialized type writes an
      # empty Array as NULL, so this column is nullable on purpose and reads back as [].
      t.string :pending_path
      # Consecutive plies with no capture and no man move; 80 of them is a draw.
      t.integer :quiet_plies, null: false, default: 0

      # Set together when the match finishes: red_won, white_won or draw, and one of
      # no_pieces, no_moves, resignation, agreement, threefold_repetition, forty_move_rule.
      t.string :result
      t.string :reason

      # Phase 5 fills this in for mode "ai": easy, medium or hard.
      t.string :ai_level
      # Phase 6 fills these in for mode "online": the single-use invite token and the side
      # that has a draw offer outstanding.
      t.string :invite_token
      t.string :draw_offered_by

      t.timestamps
    end

    add_index :matches, :invite_token, unique: true
    add_index :matches, :red_guest_key
    add_index :matches, :white_guest_key
    add_index :matches, [ :status, :updated_at ]
  end
end
