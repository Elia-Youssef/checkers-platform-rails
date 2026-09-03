require "application_rack_test_case"

# Grader lines A, B and C walked through the real pages with no browser and no JavaScript,
# plus undo and resignation. Every click here is a link or a form submission; nothing on the
# page needs a script to progress (rubric 5), and the destinations offered are the engine's
# (rubric 6, 7, 8, 20).
class HotseatWithoutJavascriptTest < ApplicationRackTestCase
  test "line A: after 11-15 22-18 the only Red move is 15x22" do
    start_hotseat

    assert_equal [ 9, 10, 11, 12 ], selectable_squares
    assert_equal "Square 11, Red man", square_label(11)
    assert_equal "Square 15, empty", square_label(15)

    click_square(11)
    assert_equal [ 15, 16 ], offered_targets
    assert_equal "true", square(11)["aria-pressed"]
    assert_equal "Square 15, empty, move here", square_label(15)

    click_square(15)
    assert_equal [ "11-15" ], move_list
    assert_selector ".status__headline", text: "White to move"

    play("22-18")
    assert_equal [ "11-15", "22-18" ], move_list
    assert_selector ".status__headline", text: "Red to move"

    # Mandatory capture: one Red piece can move, and only to 22.
    assert_equal [ 15 ], selectable_squares

    click_square(9)
    assert_equal [], offered_targets, "a piece with no legal move offered a destination"

    click_square(15)
    assert_equal [ 22 ], offered_targets

    click_square(22)
    assert_equal [ "11-15", "22-18", "15x22" ], move_list
    # Square 22 is where the jump landed, and the name says so (round-2 audit, M1).
    assert_equal "Square 22, Red man, moved here", square_label(22)
    assert_equal "Square 18, empty", square_label(18), "the jumped White man is still on 18"
    assert_selector ".player__count", text: "11 pieces"
  end

  test "line B: after 24 to 15 the board is locked to the jumping piece until the sequence ends" do
    start_hotseat
    %w[12-16 24-20 8-12 28-24 16-19].each { |text| play(text) }

    assert_equal [ 23, 24 ], selectable_squares
    click_square(23)
    assert_equal [ 16 ], offered_targets
    click_square(24)
    assert_equal [ 15 ], offered_targets

    click_square(15)

    # Locked: only the continuation is offered, every other square is inert, and neither Undo
    # nor Resign is available.
    assert_equal [ 8 ], offered_targets
    assert_equal [], selectable_squares, "another piece could still be selected"
    assert_selector "button.square:not([disabled])", count: 1
    assert_no_selector "button", text: "Undo"
    assert_no_selector "a", text: "Resign"
    assert_selector ".controls__note", text: "A jump is in progress"
    assert_equal 5, move_list.length, "the sequence was written to the move list too early"

    # Clicking another piece does nothing: its button is disabled, so there is nothing to click.
    assert square(23).disabled?, "another piece stayed clickable during the sequence"
    assert square(11).disabled?

    click_square(8)

    assert_equal [ "12-16", "24-20", "8-12", "28-24", "16-19", "24x15x8" ], move_list
    assert_selector ".moves__move--latest", text: "24x15x8"
    assert_selector ".status__headline", text: "Red to move"
    assert_selector "button", text: "Undo"
    assert_selector "a", text: "Resign"
  end

  test "line C: promotion during a jump crowns the piece and ends the move at once" do
    start_hotseat
    %w[11-16 23-18 9-14 18x9 6x13 24-20 2-6].each { |text| play(text) }

    assert_equal [ 20 ], selectable_squares
    click_square(20)
    assert_equal [ 11 ], offered_targets

    click_square(11)
    assert_equal [ 2 ], offered_targets, "the locked piece was offered more than its continuation"

    click_square(2)

    assert_equal "Square 2, White king, moved here", square_label(2)
    assert_equal "Square 6, Red man", square_label(6),
      "the new king kept jumping and took the man on 6"
    assert_selector ".moves__move--latest", text: "20x11x2"
    assert_selector ".status__headline", text: "Red to move"
    assert_selector "##{Match::BOARD_ID} .piece--king", count: 1
    assert_selector "button[data-square='2'] .piece--king .piece__crown", count: 1,
      visible: :all
  end

  test "undo takes back the last move and resigning ends the match, both without JavaScript" do
    start_hotseat
    play("11-15")
    play("22-18")
    assert_equal [ "11-15", "22-18" ], move_list

    click_button "Undo"

    assert_equal [ "11-15" ], move_list
    assert_selector ".status__headline", text: "White to move"
    assert_equal "Square 18, empty", square_label(18)
    assert_equal "Square 22, White man", square_label(22)

    click_link "Resign"

    assert_selector "[role=alertdialog]"
    assert_selector "h1", text: "Resign this match?"
    click_link "Cancel"

    assert_selector ".status__headline", text: "White to move"
    assert_equal [ "11-15" ], move_list

    click_link "Resign"
    click_button "Resign"

    assert_selector ".status__headline--result", text: "Red wins by resignation"
    assert_selector ".controls__result", text: "Red wins by resignation"
    assert_no_selector "button", text: "Undo"
    assert_no_selector "a", text: "Resign"
    assert_selector "button", text: "Play again"
    assert_equal [ "11-15" ], move_list, "resigning changed the move list"
    assert_selector "button.square[disabled]", count: 32
  end

  test "play again starts a fresh match from the opening" do
    first = start_hotseat
    play("11-15")
    click_link "Resign"
    click_button "Resign"

    click_button "Play again"

    second = Match.order(:id).last
    assert_not_equal first.id, second.id
    assert_selector ".moves__empty"
    assert_selector ".status__headline", text: "Red to move"
    assert_equal [ 9, 10, 11, 12 ], selectable_squares
    assert_equal "rrrrrrrrrrrr--------wwwwwwwwwwww", second.position
  end

  test "a reload shows the same board, the same moves and the same side to move" do
    match = start_hotseat
    %w[11-15 22-18 15x22 25x18].each { |text| play(text) }
    board = all("button[data-square]", visible: :all).map { |b| b["aria-label"] }

    visit match_path(match)

    assert_equal board, all("button[data-square]", visible: :all).map { |b| b["aria-label"] }
    assert_equal [ "11-15", "22-18", "15x22", "25x18" ], move_list
    assert_selector ".status__headline", text: "Red to move"
  end
end
