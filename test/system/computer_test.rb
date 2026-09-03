require "application_system_test_case"

# A game against the computer in a real browser. The Stimulus controller does the selecting
# and Turbo replaces the four fragments, but the reply is still the server's answer to the
# request that carried the human's move: nothing here waits for a second round trip, and the
# assertions after each click are made against the page that came back with it.
#
# The moves the computer plays are the ones config.x.ai_random_seed pins in the test
# environment (see config/environments/test.rb). Easy is used throughout for that reason:
# Hard deepens against the wall clock, so no test may name a Hard move or a game length.
class ComputerTest < ApplicationSystemTestCase
  # The seeded Easy game this test walks, human first. The computer's answer follows each
  # human move in the same response.
  HUMAN = %w[9-13 5-9 13x22 1-5 9-13 13x22x31].freeze
  COMPUTER = %w[23-18 22-17 26x17 31-26 18-14 14-9].freeze

  def square(number)
    find("##{Match::BOARD_ID} button[data-square='#{number}']")
  end

  def click_square(number)
    square(number).click
  end

  def offered_targets
    all("button.square--target").map { |button| button["data-square"].to_i }.sort
  end

  def move_list
    all(".moves__move").map(&:text)
  end

  # Starts a match from the home page, choosing the colour and the level with the form's own
  # radio buttons, exactly as a visitor does.
  def start_computer(colour:, level:)
    visit root_path
    within "#mode-computer" do
      choose "ai-colour-#{colour}"
      choose "ai-level-#{level}"
      click_button "Start a game against the computer"
    end
    assert_selector "##{Match::BOARD_ID}"
    Match.order(:id).last
  end

  # Plays one whole human move by clicking, then waits until the computer's answer is the
  # latest entry in the list. The wait is Capybara's, so a reply that never arrived fails
  # here rather than somewhere later.
  def play_against(human, reply)
    click_move(human)
    assert_selector ".moves__move--latest", text: reply
  end

  # Clicks the squares of one whole move, one leg at a time, asserting before every click that
  # the board it is about to land on is the board that click belongs to.
  #
  # Selecting a piece is painted by the Stimulus controller inside the page, so its
  # destinations appear at once; every further leg of a jump sequence is a request whose answer
  # replaces the board fragment, and Capybara resolves the next square against whatever board
  # is in the DOM at that instant. On the board that has not been replaced yet the continuation
  # square is not a target, so the click only clears the selection: the leg is lost, the move
  # never completes and the reply never arrives. That is the sixth move of the first test
  # failing about one run in three (session-7 audit, finding H1, measured at 5 of 11 seeds).
  # Waiting for the continuation square to be offered is the same wait the multi-jump lower
  # down in this file already makes by hand.
  def click_move(pdn)
    squares = pdn.split(/[-x]/).map(&:to_i)
    squares.each_cons(2) do |from, to|
      click_square(from)
      assert_selector "##{Match::BOARD_ID} button.square--target[data-square='#{to}']"
    end
    click_square(squares.last)
  end

  test "a game against Easy answers every move in the same page, through a multi-jump" do
    match = start_computer(colour: "red", level: "easy")

    assert_selector "h1", text: "Match against the computer (Easy)"
    assert_selector ".player__name", text: "Computer (Easy)"
    assert_selector ".player__name", text: "Guest"
    assert_selector ".status__headline", text: "Red to move"
    assert_selector ".moves__empty"
    assert_equal 0, match.reload.moves.count

    play_against(HUMAN[0], COMPUTER[0])

    # One request carried both moves: the human's and the answer.
    assert_equal [ HUMAN[0], COMPUTER[0] ], move_list
    assert_selector ".status__headline", text: "Red to move"
    assert_selector ".status__search", text: "Computer (Easy) replied in"
    assert_equal 2, match.reload.moves.count

    HUMAN.each_with_index.drop(1).each do |human, index|
      play_against(human, COMPUTER[index])
    end

    assert_equal HUMAN.zip(COMPUTER).flatten, move_list
    assert_includes move_list, "13x22x31"
    assert_equal 12, match.reload.moves.count
    assert_equal "13x22x31", match.moves.order(:ply).find_by(ply: 11).pdn

    # Undo takes back the human's last move and the computer's answer together.
    click_button "Undo"

    assert_selector ".moves__move--latest", text: COMPUTER[4]
    assert_equal 10, move_list.length
    assert_selector ".status__headline", text: "Red to move"
    assert_equal 10, match.reload.moves.count

    # And the multi-jump can be played again, one leg at a time, locked to the jumping piece.
    click_square(13)
    assert_equal [ 22 ], offered_targets
    click_square(22)
    assert_selector ".controls__note", text: "A jump is in progress"
    assert_equal [ 31 ], offered_targets
    assert_no_selector "button", text: "Undo"
    click_square(31)
    assert_selector ".moves__move--latest", text: COMPUTER[5]
    assert_equal 12, match.reload.moves.count

    # Resigning ends it as a win for the computer's colour, with the computer named.
    click_link "Resign"
    assert_selector "h1", text: "Resign this match?"
    click_button "Resign"

    assert_selector ".status__headline--result", text: "White wins by resignation"
    assert_selector ".player__name", text: "Computer (Easy)"
    assert_no_selector "button", text: "Undo"
    assert_selector "button.square[disabled]", count: 32

    match.reload
    assert_equal "white_won", match.result
    assert_equal "resignation", match.reason
  end

  test "playing White opens the board with the computer's first move already made" do
    match = start_computer(colour: "white", level: "medium")

    assert_equal 1, match.reload.moves.count
    assert_equal "red", match.moves.first.side
    assert_equal [ match.moves.first.pdn ], move_list
    assert_selector ".status__headline", text: "White to move"
    assert_selector ".status__search", text: "Computer (Medium) replied at depth 4 in"
    assert_selector ".player__name", text: "Computer (Medium)"

    # Undo has nothing of the human's to take back yet.
    assert_no_selector "button", text: "Undo"
    assert_selector "a", text: "Resign"
  end

  test "Play again starts the same colour and level again" do
    first = start_computer(colour: "white", level: "easy")
    click_link "Resign"
    assert_selector "h1", text: "Resign this match?"
    click_button "Resign"
    assert_selector ".status__headline--result", text: "Red wins by resignation"

    click_button "Play again"

    assert_selector "h1", text: "Match against the computer (Easy)"
    second = Match.order(:id).last
    assert_not_equal first.id, second.id
    assert_equal "ai", second.mode
    assert_equal "easy", second.ai_level
    assert_equal "white", second.human_side
    assert_selector ".status__headline", text: "White to move"
  end
end
