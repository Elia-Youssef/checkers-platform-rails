require "application_rack_test_case"

# A match against the computer with no browser and no JavaScript at all: the rack_test driver
# only follows links and submits forms, so a green test here proves that the whole game
# against the computer is carried by the pages the server sends (rubric 5 and 13).
class ComputerWithoutJavascriptTest < ApplicationRackTestCase
  test "a Red match against Medium plays, undoes two plies and resigns without JavaScript" do
    match = start_computer(colour: "red", level: "medium")

    assert_selector "h1", text: "Match against the computer (Medium)"
    assert_selector ".player__name", text: "Computer (Medium)"
    assert_selector ".status__headline", text: "Red to move"
    assert_equal [ 9, 10, 11, 12 ], selectable_squares

    click_square(11)
    assert_equal [ 15, 16 ], offered_targets

    click_square(15)

    # One form post carried the move and came back with the answer already played.
    list = move_list
    assert_equal 2, list.length, "the computer's reply is not on the page the form post returned"
    assert_equal "11-15", list.first
    assert_selector ".status__headline", text: "Red to move"
    assert_selector ".status__search", text: "Computer (Medium) replied at depth 4 in"

    match.reload
    assert_equal 2, match.moves.count
    assert_equal "white", match.moves.last.side
    assert_equal list.last, match.moves.last.pdn
    assert_equal Draughts::AI::MEDIUM_DEPTH, match.moves.last.ai_depth

    click_button "Undo"

    assert_selector ".moves__empty"
    assert_selector ".status__headline", text: "Red to move"
    assert_no_selector ".status__search"
    assert_equal 0, match.reload.moves.count

    click_link "Resign"
    assert_selector "h1", text: "Resign this match?"
    click_button "Resign"

    assert_selector ".status__headline--result", text: "White wins by resignation"
    assert_selector ".player__name", text: "Computer (Medium)"
    assert_no_selector "button", text: "Undo"
    assert_equal "white_won", match.reload.result
  end

  test "a White match against Easy opens with the computer's move and answers the next one" do
    match = start_computer(colour: "white", level: "easy")

    opening = match.reload.moves.first
    assert_equal "red", opening.side
    assert_equal [ opening.pdn ], move_list
    assert_selector ".status__headline", text: "White to move"
    assert_no_selector "button", text: "Undo"

    # White's own reply: pick the first square the page offers and the first target it lists.
    from = selectable_squares.first
    click_square(from)
    click_square(offered_targets.first)

    assert_equal 3, move_list.length
    assert_selector ".status__headline", text: "White to move"
    assert_equal 3, match.reload.moves.count
    assert_equal "red", match.moves.last.side
    assert_selector "button", text: "Undo"
  end
end
