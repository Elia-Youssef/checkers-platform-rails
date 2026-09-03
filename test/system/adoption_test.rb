require "application_system_test_case"

# Guest adoption in a real browser (rubric 43's adoption scenario, rubric 24).
#
# One browser, one cookie jar: a visitor plays without an account, then signs up, and the games
# they had already started are theirs. Nothing is stitched together by hand here, every step is
# a click on the page a visitor would see.
class AdoptionTest < ApplicationSystemTestCase
  test "a guest who signs up keeps the games they started in this browser" do
    # Two games as a guest: one hot-seat, one against the computer at Easy as Red.
    visit root_path
    within("#mode-hotseat") { click_button "Start a hot-seat game" }
    assert_selector "##{Match::BOARD_ID}"
    hotseat = Match.order(:id).last
    assert_selector ".player__name", text: "Guest"

    click_square(11)
    assert_selector "button[data-square='15'].square--target"
    click_square(15)
    assert_selector ".moves__move--latest", text: "11-15"

    visit root_path
    within "#mode-computer" do
      choose "ai-colour-red"
      choose "ai-level-easy"
      click_button "Start a game against the computer"
    end
    assert_selector "##{Match::BOARD_ID}"
    computer = Match.order(:id).last

    # My games lists both, under the guest.
    click_link "My games"
    assert_selector "tr#match-row-#{hotseat.id} .games__opponent", text: "Yourself, both seats"
    assert_selector "tr#match-row-#{computer.id} .games__opponent", text: "Computer (Easy)"
    assert_selector "tr#match-row-#{hotseat.id} .games__count", text: "1 move"

    # Sign up in the same browser, from the masthead. The link is named there and again in the
    # note this page shows a guest, so the click says which one it means.
    within(".masthead__nav") { click_link "Sign up" }
    fill_in "Email address", with: "newcomer@example.com"
    fill_in "Display name", with: "Newcomer"
    fill_in "Password", with: "a-good-password"
    fill_in "Repeat password", with: "a-good-password"
    click_button "Sign up"
    assert_selector ".masthead__identity", text: "Newcomer"

    # Both games are the account's now, and the board below names it on both seats. The
    # hot-seat row still names no opponent, because one identity holds both of its seats
    # before and after the adoption (round-2 adoption audit, finding L5).
    click_link "My games"
    assert_selector "tr#match-row-#{hotseat.id} .games__opponent", text: "Yourself, both seats"
    assert_selector "tr#match-row-#{computer.id} .games__opponent", text: "Computer (Easy)"
    assert_no_selector ".games__opponent", text: "Guest"

    within("#match-row-#{hotseat.id}") { click_link "Open" }
    assert_selector "##{Match::BOARD_ID}"
    assert_selector ".player__name", text: "Newcomer", count: 2
    assert_no_selector ".player__name", text: "Guest"
    assert_selector ".moves__move", text: "11-15"

    # And the account can go on playing the adopted game.
    click_square(22)
    assert_selector "button[data-square='18'].square--target"
    click_square(18)
    assert_selector ".moves__move--latest", text: "22-18"
    assert_equal users_named("Newcomer"), hotseat.reload.red_user
    assert_equal users_named("Newcomer"), hotseat.white_user
  end

  private
    # Every board click here is followed by an assertion about the board before the next one,
    # so a click can never land on a fragment Turbo is about to replace (session-7 audit,
    # finding H1).
    def click_square(number)
      find("##{Match::BOARD_ID} button[data-square='#{number}']").click
    end

    def users_named(name)
      User.find_by!(display_name: name)
    end
end
