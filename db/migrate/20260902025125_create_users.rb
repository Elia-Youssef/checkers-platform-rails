class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :email_address, null: false
      t.string :password_digest, null: false
      # The name shown on boards, in move lists and in the navigation. 2 to 24 characters,
      # required at sign up (TASK-BRIEF.md section 1.5). Added to the generated migration
      # rather than to a second one because SQLite refuses ADD COLUMN NOT NULL without a
      # default, and this schema has never been created anywhere.
      t.string :display_name, null: false

      t.timestamps
    end
    add_index :users, :email_address, unique: true
  end
end
