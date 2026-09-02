require "test_helper"

# One move row, and the value object the engine gets back from it.
class MoveTest < ActiveSupport::TestCase
  def match
    @match ||= Match.open_hotseat(guest_key: "guest-key-for-tests")
  end

  def row(**overrides)
    match.moves.new({ ply: 1, side: "red", pdn: "11-15", origin: 11, landings: [ 15 ],
                      captures: [], promoted: false,
                      position_after: "rrrrrrrrrr-r--r-----wwwwwwwwwwww" }.merge(overrides))
  end

  test "a valid row saves and rebuilds the engine's move" do
    saved = row
    assert saved.save

    move = saved.to_engine_move
    assert_equal "11-15", move.pdn
    assert_equal 11, move.origin
    assert_equal [ 15 ], move.landings
    assert_empty move.captures
    assert_not move.capture?
    assert_not move.promotion?
    assert_equal "white", saved.side_after
  end

  test "a jump row rebuilds every landing and every captured square" do
    saved = row(pdn: "24x15x8", origin: 24, landings: [ 15, 8 ], captures: [ 19, 11 ],
                side: "white")
    assert saved.save

    move = saved.to_engine_move
    assert_equal "24x15x8", move.pdn
    assert_equal [ 15, 8 ], move.landings
    assert_equal [ 19, 11 ], move.captures
    assert move.capture?
    assert saved.capture?
    assert_equal 2, move.capture_count
    assert_equal "red", saved.side_after
  end

  test "an empty captures array survives the round trip as an empty array" do
    saved = row
    saved.save!

    assert_equal [], Move.find(saved.id).captures
    assert_nil Move.find(saved.id).read_attribute_before_type_cast(:captures),
      "an empty serialized Array is stored as NULL, which is why the column is nullable"
  end

  test "the side, the position and the square numbers are validated" do
    assert_not row(side: "blue").valid?
    assert_not row(position_after: "short").valid?
    assert_not row(origin: 33).valid?
    assert_not row(landings: [ 0 ]).valid?
    assert_not row(captures: [ 99 ]).valid?
    assert_not row(ply: 0).valid?
    assert_not row(pdn: "").valid?
  end

  test "two rows cannot share a ply in one match" do
    row.save!
    duplicate = row

    assert_not duplicate.valid?
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save(validate: false) }
  end

  test "deleting a match deletes its moves" do
    row.save!

    assert_difference -> { Move.count }, -1 do
      match.destroy!
    end
  end
end
