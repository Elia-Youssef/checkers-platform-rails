class User < ApplicationRecord
  DISPLAY_NAME_RANGE = 2..24
  MINIMUM_PASSWORD_LENGTH = 8

  has_secure_password
  has_many :sessions, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  normalizes :display_name, with: ->(name) { name.strip }

  validates :email_address, presence: true, uniqueness: true,
    format: { with: URI::MailTo::EMAIL_REGEXP, message: "is not a valid email address" }
  validates :display_name, presence: true, length: { in: DISPLAY_NAME_RANGE }
  # has_secure_password already requires a password on create and caps it at 72 characters
  # (the bcrypt limit); allow_nil keeps updates that do not touch the password valid.
  validates :password, length: { minimum: MINIMUM_PASSWORD_LENGTH }, allow_nil: true
  # A password reset has to change the password. has_secure_password only demands one when the
  # digest is blank, so without this an update carrying nothing usable (no password parameter, a
  # blank one, or one shaped as an array or a hash, which strong parameters drop) would be a
  # valid no-op that looks exactly like success. Saved with save(context: :password_reset), so
  # it is the model, not a controller guard, that refuses it.
  validates :password, presence: true, on: :password_reset
end
