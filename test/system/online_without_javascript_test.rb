require "application_rack_test_case"

# The whole online flow with JavaScript switched off, in two browsers.
#
# Capybara's rack_test driver has no JavaScript engine at all: it can follow a link and submit
# a form, and nothing else. There are no Turbo Streams here and no sockets, so every page in
# this test is a page the server rendered in answer to a request, and every step is a form
# post followed by a redirect. What it proves is that online play needs the browser for
# nothing: creating, sending the invite, joining, selecting a piece, playing a leg, offering a
# draw and accepting it are all plain HTML.
#
# Two named sessions are two cookie jars, which is what two players are.
class OnlineWithoutJavascriptTest < ApplicationRackTestCase
  def sign_in_as(user)
    visit new_session_path
    fill_in "Email address", with: user.email_address
    fill_in "Password", with: "password"
    click_button "Sign in"
    assert_selector ".masthead__identity", text: user.display_name
  end

  # Selects a piece and plays one leg, each click a form submission and a fresh page.
  def play(pdn)
    squares = pdn.split(/[-x]/).map(&:to_i)
    click_square(squares.first)
    squares.drop(1).each { |landing| click_square(landing) }
  end

  test "two players create, join, move, offer and accept a draw with no JavaScript" do
    invite = nil

    Capybara.using_session(:ada) do
      sign_in_as users(:one)
      visit root_path
      within "#mode-online" do
        choose "online-colour-red"
        click_button "Create an online match"
      end

      # The waiting page: the link as text and as a link, no copy button (it needs
      # JavaScript, so it is not rendered as a control that cannot work), and Cancel.
      assert_text "Waiting for a second player"
      assert_no_button "Copy link"
      assert_button "Cancel this match"
      invite = find("##{Match::INVITE_ID} input", visible: :all).value
      assert_link invite
      # Nothing on the board can be touched yet.
      assert_equal [], selectable_squares
      assert_selector "button.square[disabled]", count: 32
    end

    match = Match.order(:id).last
    assert_equal "waiting", match.status
    assert_operator invite.split("/").last.length, :>=, 20

    # Grace opens the link. That is the whole join.
    Capybara.using_session(:grace) do
      sign_in_as users(:two)
      visit invite
      assert_text "You joined this match as White"
      assert_text "Waiting for Ada to move"
      assert_equal [], selectable_squares, "White could select a piece on Red's turn"
    end
    assert_equal "active", match.reload.status

    # Ada reloads and sees the active board. With no JavaScript this is what a second player
    # joining looks like: the page is right the next time it is asked for.
    Capybara.using_session(:ada) do
      visit match_path(match)
      assert_text "Your move"
      assert_no_selector "##{Match::INVITE_ID} input"
      assert_equal [ 9, 10, 11, 12 ], selectable_squares

      click_square(11)
      assert_equal [ 15, 16 ], offered_targets
      click_square(15)
      assert_equal [ "11-15" ], move_list
      assert_text "White to move"
      assert_equal [], selectable_squares, "Red could still select after moving"
    end

    Capybara.using_session(:grace) do
      visit match_path(match)
      assert_equal [ "11-15" ], move_list
      assert_text "Your move"
      play("22-18")
      assert_equal [ "11-15", "22-18" ], move_list
    end

    # A draw, offered and accepted through plain forms.
    Capybara.using_session(:ada) do
      visit match_path(match)
      assert_equal [ "11-15", "22-18" ], move_list
      click_button "Offer a draw"
      assert_text "Draw offered"
      assert_text "You have offered a draw"
      assert_no_button "Offer a draw"
    end

    Capybara.using_session(:grace) do
      visit match_path(match)
      assert_text "Ada (Red) has offered a draw"
      click_button "Decline"
      assert_text "Draw offer declined"
      assert_no_button "Accept the draw"
    end

    Capybara.using_session(:ada) do
      visit match_path(match)
      assert_no_text "has offered a draw"
      click_button "Offer a draw"
    end

    Capybara.using_session(:grace) do
      visit match_path(match)
      click_button "Accept the draw"
      assert_text "Draw by agreement"
      assert_no_button "Offer a draw"
      assert_button "Play again"
    end

    match.reload
    assert_equal "finished", match.status
    assert_equal "draw", match.result
    assert_equal "agreement", match.reason

    # And the finished board is the same for the other player, without JavaScript.
    Capybara.using_session(:ada) do
      visit match_path(match)
      assert_text "Draw by agreement"
      assert_equal [ "11-15", "22-18" ], move_list
    end
  end

  test "the join field on the home page takes a whole invite link" do
    match = Match.open_online(creator: users(:one), colour: "white")

    Capybara.using_session(:grace) do
      sign_in_as users(:two)
      visit root_path
      within "#mode-join" do
        fill_in "Invite link or code", with: "http://www.example.com/join/#{match.invite_token}"
        click_button "Join the match"
      end
      assert_text "You joined this match as Red"
    end

    assert_equal "active", match.reload.status
    assert_equal users(:two), match.red_user
  end

  test "a rematch is offered and joined with no JavaScript" do
    match = Match.open_online(creator: users(:one), colour: "red")
    match.join!(users(:two))
    match.resign!("white")

    Capybara.using_session(:ada) do
      sign_in_as users(:one)
      visit match_path(match)
      assert_text "Red wins by resignation"
      click_button "Play again"
      assert_text "Waiting for a second player"
    end
    rematch = Match.order(:id).last

    Capybara.using_session(:grace) do
      sign_in_as users(:two)
      visit match_path(match)
      assert_text "Ada has started a rematch"
      click_link "Join the rematch"
      assert_text "Your move"
    end

    rematch.reload
    assert_equal "active", rematch.status
    assert_equal users(:two), rematch.red_user
    assert_equal users(:one), rematch.white_user
  end
end
