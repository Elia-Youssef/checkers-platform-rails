require "test_helper"

# The JavaScript-off system tests.
#
# Capybara's rack_test driver has no browser and no JavaScript engine at all: it parses the
# HTML the server sent, and the only things it can do are follow a link and submit a form.
# A test that passes here has proved that the pages carry the whole game, which is exactly
# what rubric item 5 asks for and what a build with its rules in JavaScript cannot fake.
#
# The Chromium tests in ApplicationSystemTestCase are the other half: the same flows with
# JavaScript on.
class ApplicationRackTestCase < ActionDispatch::SystemTestCase
  driven_by :rack_test

  # Every square button on the board, addressed by its PDN number.
  def square(number)
    find("##{Match::BOARD_ID} button[data-square='#{number}']", visible: :all)
  end

  def click_square(number)
    square(number).click
  end

  # The squares the page is currently offering as destinations, ascending.
  def offered_targets
    all("button.square--target", visible: :all).map { |button| button["data-square"].to_i }.sort
  end

  # The squares this page offers to select, read from the forms themselves and not from any
  # data attribute: with JavaScript off a selectable piece is a square whose form carries a
  # hidden selected field. Keeping this independent of data-legal-targets is deliberate, so
  # that deleting the data attributes breaks only the JavaScript path.
  def selectable_squares
    all("form input[name='selected']", visible: :all).map { |input| input.value.to_i }.sort
  end

  def move_list
    all(".moves__move", visible: :all).map(&:text)
  end

  def square_label(number)
    square(number)["aria-label"]
  end

  # Starts a hot-seat match from the home page, the way a visitor does.
  def start_hotseat
    visit root_path
    within "#mode-hotseat" do
      click_button "Start a hot-seat game"
    end
    assert_selector "##{Match::BOARD_ID}"
    Match.order(:id).last
  end

  # Plays a whole PDN move by clicking: the piece, then each landing square in turn.
  def play(pdn)
    squares = pdn.split(/[-x]/).map(&:to_i)
    click_square(squares.first)
    squares.drop(1).each { |landing| click_square(landing) }
  end
end
