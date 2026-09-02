require "test_helper"

class UserTest < ActiveSupport::TestCase
  # The pinned rules (TASK-BRIEF.md section 2): a display name of 2 to 24 characters and a
  # password of at least 8 characters.
  def new_user(**overrides)
    User.new({
      email_address: "nina@example.com",
      display_name: "Nina",
      password: "correct horse",
      password_confirmation: "correct horse"
    }.merge(overrides))
  end

  test "downcases and strips email_address" do
    user = User.new(email_address: " DOWNCASED@EXAMPLE.COM ")
    assert_equal("downcased@example.com", user.email_address)
  end

  test "a complete sign up is valid" do
    assert_predicate new_user, :valid?
  end

  test "display name of one character is refused" do
    user = new_user(display_name: "N")

    assert_not_predicate user, :valid?
    assert_includes user.errors.full_messages_for(:display_name).to_sentence, "too short"
  end

  test "display name of two characters is accepted" do
    assert_predicate new_user(display_name: "Ni"), :valid?
  end

  test "display name of twenty-four characters is accepted" do
    name = "N" * 24

    assert_equal 24, name.length
    assert_predicate new_user(display_name: name), :valid?
  end

  test "display name of twenty-five characters is refused" do
    user = new_user(display_name: "N" * 25)

    assert_not_predicate user, :valid?
    assert_includes user.errors.full_messages_for(:display_name).to_sentence, "too long"
  end

  test "display name is stripped before it is measured" do
    assert_equal "Nina", new_user(display_name: "  Nina  ").display_name
    assert_not_predicate new_user(display_name: "  N  "), :valid?
  end

  test "display name is required" do
    user = new_user(display_name: "")

    assert_not_predicate user, :valid?
    assert_includes user.errors.full_messages_for(:display_name).to_sentence, "blank"
  end

  test "password of seven characters is refused" do
    user = new_user(password: "1234567", password_confirmation: "1234567")

    assert_not_predicate user, :valid?
    assert_includes user.errors.full_messages_for(:password).to_sentence, "too short"
  end

  test "password of eight characters is accepted" do
    assert_predicate new_user(password: "12345678", password_confirmation: "12345678"), :valid?
  end

  test "password is required" do
    user = new_user(password: nil, password_confirmation: nil)

    assert_not_predicate user, :valid?
    assert_includes user.errors.full_messages_for(:password).to_sentence, "blank"
  end

  test "password confirmation has to match" do
    user = new_user(password_confirmation: "something else")

    assert_not_predicate user, :valid?
    assert_includes user.errors.full_messages.to_sentence, "Password confirmation"
  end

  test "email address has to be unique whatever its case or spacing" do
    user = new_user(email_address: "  #{users(:one).email_address.upcase}  ")

    assert_not_predicate user, :valid?
    assert_includes user.errors.full_messages_for(:email_address).to_sentence, "taken"
  end

  test "email address has to look like an email address" do
    user = new_user(email_address: "not-an-email")

    assert_not_predicate user, :valid?
    assert_includes user.errors.full_messages_for(:email_address).to_sentence, "not a valid email address"
  end

  test "the fixtures carry a display name" do
    assert_equal "Ada", users(:one).display_name
    assert_predicate users(:one), :valid?
  end
end
