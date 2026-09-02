class CreateMoves < ActiveRecord::Migration[8.1]
  def change
    create_table :moves do |t|
      t.references :match, null: false, foreign_key: true
      # 1 for the first move of the match, and one row per completed move: a whole jump
      # sequence is one move, so 24x15x8 is a single row.
      t.integer :ply, null: false
      t.string :side, null: false
      t.string :pdn, null: false
      t.integer :origin, null: false
      # JSON arrays of PDN square numbers: one landing square per leg, one captured square
      # per leg. captures is NULL for a quiet move, because Active Record's serialized type
      # writes an empty Array as NULL; it reads back as [].
      t.string :landings, null: false
      t.string :captures
      t.boolean :promoted, null: false, default: false
      # The engine's 32-character position after this move.
      t.string :position_after, null: false

      t.timestamps
    end

    add_index :moves, [ :match_id, :ply ], unique: true
  end
end
