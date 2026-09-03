class AddSearchEvidenceToMoves < ActiveRecord::Migration[8.1]
  # What the computer's search did for the move on this row. NULL on every move a person
  # played, which is also how a row says who played it without duplicating the seat rule.
  #
  # RUBRIC.md item 10 asks for the reached depth to be readable, and the search is the only
  # place that knows it, so the number is stored with the move rather than only logged: a
  # reload, another browser and a container restart all show the same sentence in the status
  # panel, which a flash message could not survive.
  def change
    change_table :moves, bulk: true do |t|
      # The depth iterative deepening completed, 4 for Medium, 0 for Easy (no search).
      t.integer :ai_depth
      # Positions the search visited, 0 for Easy.
      t.integer :ai_nodes
      # Milliseconds of the clock the search was given, rounded.
      t.integer :ai_elapsed_ms
    end
  end
end
