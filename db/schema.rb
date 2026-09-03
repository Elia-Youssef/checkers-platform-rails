# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_02_160000) do
  create_table "matches", force: :cascade do |t|
    t.string "ai_level"
    t.datetime "created_at", null: false
    t.string "draw_offered_by"
    t.string "invite_token"
    t.datetime "invite_token_used_at"
    t.string "mode", null: false
    t.string "pending_path"
    t.string "position", null: false
    t.integer "quiet_plies", default: 0, null: false
    t.string "reason"
    t.string "red_guest_key"
    t.integer "red_user_id"
    t.integer "rematch_match_id"
    t.string "result"
    t.string "side_to_move", default: "red", null: false
    t.string "start_position", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.string "white_guest_key"
    t.integer "white_user_id"
    t.index ["invite_token"], name: "index_matches_on_invite_token", unique: true
    t.index ["red_guest_key"], name: "index_matches_on_red_guest_key"
    t.index ["red_user_id"], name: "index_matches_on_red_user_id"
    t.index ["rematch_match_id"], name: "index_matches_on_rematch_match_id"
    t.index ["status", "updated_at"], name: "index_matches_on_status_and_updated_at"
    t.index ["white_guest_key"], name: "index_matches_on_white_guest_key"
    t.index ["white_user_id"], name: "index_matches_on_white_user_id"
  end

  create_table "moves", force: :cascade do |t|
    t.integer "ai_depth"
    t.integer "ai_elapsed_ms"
    t.integer "ai_nodes"
    t.string "captures"
    t.datetime "created_at", null: false
    t.string "landings", null: false
    t.integer "match_id", null: false
    t.integer "origin", null: false
    t.string "pdn", null: false
    t.integer "ply", null: false
    t.string "position_after", null: false
    t.boolean "promoted", default: false, null: false
    t.string "side", null: false
    t.datetime "updated_at", null: false
    t.index ["match_id", "ply"], name: "index_moves_on_match_id_and_ply", unique: true
    t.index ["match_id"], name: "index_moves_on_match_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "display_name", null: false
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "matches", "matches", column: "rematch_match_id"
  add_foreign_key "matches", "users", column: "red_user_id"
  add_foreign_key "matches", "users", column: "white_user_id"
  add_foreign_key "moves", "matches"
  add_foreign_key "sessions", "users"
end
