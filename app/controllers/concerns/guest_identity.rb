# Identifies a visitor who has no account.
#
# A guest can play hot-seat and versus the computer (TASK-BRIEF.md section 1.5). The
# identity is a random URL-safe key in a signed, HttpOnly, SameSite=Lax cookie that lives
# for a year and is created on the first visit. Signed means the browser cannot invent or
# edit a key: a tampered cookie fails verification, reads as nil and is replaced with a
# fresh one, so a guest can never take over another guest's matches by editing a cookie.
#
# The key is exposed as Current.guest_key for the whole request. Matches created by a guest
# store it, and a later phase adopts those matches when that browser signs up or signs in.
module GuestIdentity
  extend ActiveSupport::Concern

  COOKIE_NAME = :guest_key
  COOKIE_LIFETIME = 1.year
  # 24 random bytes, which SecureRandom encodes as 32 URL-safe characters.
  KEY_BYTES = 24

  included do
    before_action :resume_or_start_guest_identity
  end

  private
    def resume_or_start_guest_identity
      Current.guest_key = cookies.signed[COOKIE_NAME].presence || start_guest_identity
    end

    def start_guest_identity
      SecureRandom.urlsafe_base64(KEY_BYTES).tap do |key|
        cookies.signed[COOKIE_NAME] = {
          value: key,
          expires: COOKIE_LIFETIME.from_now,
          httponly: true,
          same_site: :lax
        }
      end
    end
end
