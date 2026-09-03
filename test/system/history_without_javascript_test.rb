require "application_rack_test_case"

# My games, the replay and the export with no browser and no JavaScript at all (rubric 5).
#
# Every step is a link this application rendered, followed by a driver that cannot run a
# script. If any of the three pages needed JavaScript to be usable, this test could not reach
# the end of the game.
class HistoryWithoutJavascriptTest < ApplicationRackTestCase
  test "a guest walks from My games into a replay and out to the export" do
    match = start_hotseat
    play("11-15")
    play("22-18")
    play("15x22")
    assert_equal [ "11-15", "22-18", "15x22" ], move_list

    click_link "My games"
    assert_selector "h1", text: "My games"
    within("#match-row-#{match.id}") do
      assert_text "Hot-seat"
      assert_text "Yourself, both seats"
      assert_text "3 moves"
      click_link "Open"
    end
    assert_selector "##{Match::BOARD_ID}"

    # Finish the game so that the match page offers the replay and the export. It is White to
    # move after 15x22, so White is the side that resigns and Red wins.
    click_link "Resign"
    click_button "Resign"
    assert_selector ".controls__result", text: "Red wins by resignation"

    click_link "Replay"
    assert_selector ".replay__ply", text: "The starting position"
    assert_equal Draughts::Position::START_BOARD, find(".replay__position").text

    click_link "Next"
    assert_selector ".replay__ply", text: "After ply 1 of 3"
    assert_selector ".moves__move--latest", text: "11-15"

    click_link "Last"
    assert_selector ".replay__ply", text: "After ply 3 of 3"
    assert_selector ".moves__move--latest", text: "15x22"
    assert_equal match.reload.position, find(".replay__position").text

    click_link "Back to the match"
    assert_selector "##{Match::BOARD_ID}"

    # The export is a plain link too: no browser, no script, a file.
    click_link "Export PDN"
    assert_match(/\A\[Event "Checkers on Rails, hot-seat game"\]/, page.body)
    assert_includes page.body, %([GameType "21"])
    assert_includes page.body, "1. 11-15 22-18 2. 15x22"
    assert_equal "1-0", page.body.split(/\s+/).last
  end
end
