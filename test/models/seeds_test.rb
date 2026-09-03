require "test_helper"

# db/seeds.rb: two demo accounts and one finished demo game (TASK-BRIEF 1.7, rubric 40 and 36).
#
# The seed file is loaded here for real, inside the test transaction, which is the only way to
# know that it still runs and that it is still idempotent. bin/ci also loads it on a clean
# database (the Tests: Seeds step), so between the two, "it works on a fresh install" is not a
# claim anybody has to take on trust.
class SeedsTest < ActionDispatch::IntegrationTest
  SEEDS = Rails.root.join("db/seeds.rb")
  PASSWORD = "demo-checkers"
  EMAILS = %w[ demo-red@example.com demo-white@example.com ].freeze

  # Loads db/seeds.rb and returns what it printed.
  def load_seeds
    captured = StringIO.new
    original, $stdout = $stdout, captured
    load SEEDS
    captured.string
  ensure
    $stdout = original
  end

  def demo_match
    Match.where(mode: "online").order(:id).last
  end

  test "loading the seeds a second time creates nothing and changes nothing" do
    first = load_seeds
    counts = [ User.count, Match.count, Move.count ]
    before = Match.order(:id).pluck(:id, :updated_at, :position, :result)
    assert_match(/demo game: match \d+, red_won by no_pieces, 103 moves/, first)

    second = load_seeds

    assert_equal counts, [ User.count, Match.count, Move.count ], "a second run created rows"
    assert_equal before, Match.order(:id).pluck(:id, :updated_at, :position, :result)
    assert_match(/already here/, second)
    assert_equal 2, User.where(email_address: EMAILS).count
  end

  test "both demo accounts sign in with the documented password" do
    load_seeds

    EMAILS.each do |email|
      assert User.authenticate_by(email_address: email, password: PASSWORD),
        "#{email} did not sign in with the password the README documents"
    end
    assert_equal "Demo Red", User.find_by(email_address: EMAILS.first).display_name
    assert_equal "Demo White", User.find_by(email_address: EMAILS.last).display_name

    post session_path, params: { email_address: EMAILS.first, password: PASSWORD }
    assert_response :redirect
    follow_redirect!
    assert_select ".masthead__identity", "Demo Red"
  end

  test "the demo game is finished, and every stored position is the engine's own" do
    load_seeds
    match = demo_match

    assert_equal "finished", match.status
    assert_equal "red_won", match.result
    assert_equal "no_pieces", match.reason
    assert_equal 103, match.moves.count
    assert_equal "Demo Red", match.red_user.display_name
    assert_equal "Demo White", match.white_user.display_name
    assert match.invite_token_used_at.present?, "the invite was joined, not faked"

    # The independent check: replay the stored PDN text through a fresh engine and compare
    # every position it produces with the one stored on that move row (rubric 36).
    game = Draughts::Game.new
    match.moves.each do |row|
      game.play(row.pdn)
      assert_equal row.position_after, game.position.board_string,
        "the position stored after ply #{row.ply} (#{row.pdn})"
      assert_equal(row.ply.odd? ? "red" : "white", row.side,
        "Red moves first and the sides alternate, so ply #{row.ply}")
    end
    assert_equal match.position, game.position.board_string, "the match's own position column"
    assert_equal match.result, game.result.to_s, "the engine's verdict, not a written status"
    assert_equal match.reason, game.reason.to_s
    assert_equal 0, game.position.count(Draughts::Side::WHITE), "White really has no pieces"
  end

  # ---- where the demo data is created, and where it is not ------------------------------

  # The production image runs bin/rails db:prepare on first boot, which loads db/seeds.rb, so
  # without a guard every production container would come up carrying two accounts whose
  # password is published in the README (session-7 audit, finding M1). The decision is a method
  # so that it can be asked here directly, one case per line.
  test "the demo data is wanted everywhere but production, and there only with DEMO_SEEDS=1" do
    load_seeds

    assert DemoSeeds.wanted?("development", nil), "development always seeds the demo data"
    assert DemoSeeds.wanted?("test", nil), "test always seeds the demo data"
    assert DemoSeeds.wanted?(:development, "0"), "DEMO_SEEDS does not switch development off"

    assert_not DemoSeeds.wanted?("production", nil), "production with no DEMO_SEEDS"
    assert_not DemoSeeds.wanted?("production", ""), "production with an empty DEMO_SEEDS"
    assert_not DemoSeeds.wanted?("production", "0")
    assert_not DemoSeeds.wanted?("production", "true")
    assert_not DemoSeeds.wanted?("production", "yes")

    assert DemoSeeds.wanted?("production", "1"), "production with DEMO_SEEDS=1"
    assert DemoSeeds.wanted?(:production, " 1 "), "a value typed with stray spaces still counts"
  end

  test "loading the seeds in production creates nothing and says how to opt in" do
    load_seeds
    counts = [ User.count, Match.count, Move.count ]

    environment = Rails.env
    output = nil
    begin
      Rails.env = "production"
      output = load_seeds
    ensure
      Rails.env = environment.to_s
    end

    assert_equal counts, [ User.count, Match.count, Move.count ],
      "the production run created or destroyed rows"
    assert_match(/no demo accounts and no demo game were created/, output)
    assert_match(/DEMO_SEEDS=1/, output)
    assert_no_match(/demo game: match/, output)
  end

  # find_or_create_by! sets the password only when it creates, so the closing line may not
  # claim the documented password for an account that was already here (finding L1).
  test "the closing line says what it created and what it left alone" do
    first = load_seeds
    assert_match(/accounts created: demo-red@example.com, demo-white@example.com \(password demo-checkers\)/, first)
    assert_no_match(/left unchanged/, first)

    second = load_seeds

    assert_match(/accounts already here, left unchanged: demo-red@example.com, demo-white@example.com/, second)
    assert_no_match(/accounts created/, second)
  end

  test "the seeded game replays and exports on a fresh database" do
    load_seeds
    match = demo_match

    get match_replay_path(match, ply: 0)
    assert_response :success
    assert_select ".replay__position", text: Draughts::Position::START_BOARD

    get match_replay_path(match, ply: 103)
    assert_response :success
    assert_select ".replay__position", text: match.position
    assert_select ".moves__move--latest", text: match.moves.last.pdn

    get match_path(match, format: :pdn)
    assert_response :success
    assert_includes response.body, %([Red "Demo Red"])
    assert_includes response.body, %([White "Demo White"])
    assert_includes response.body, "1. 11-16 23-19"
    assert_equal "1-0", response.body.split(/\s+/).last
  end
end
