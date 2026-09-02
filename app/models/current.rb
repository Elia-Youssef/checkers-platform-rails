class Current < ActiveSupport::CurrentAttributes
  attribute :session
  # The signed cookie key that identifies a visitor without an account. Set on every
  # request by the GuestIdentity concern, so hot-seat and versus-computer matches can
  # belong to a browser rather than to a user. Never nil inside a request.
  attribute :guest_key
  delegate :user, to: :session, allow_nil: true
end
