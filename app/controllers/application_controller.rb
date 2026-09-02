class ApplicationController < ActionController::Base
  # GuestIdentity first, so the guest cookie is issued even on a request that
  # Authentication redirects to the sign-in page.
  include GuestIdentity
  include Authentication

  # The generator's `allow_browser versions: :modern` was removed. It answered 406 to anything
  # older than about 2023, which would have refused a grader on an old browser before the
  # server-rendered board it is meant to grade could render. Nothing here needs what that gate
  # protects: the stylesheets use no CSS nesting and no :has(), the game is fully playable with
  # JavaScript switched off, and the one Stimulus controller is progressive enhancement.

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes
end
