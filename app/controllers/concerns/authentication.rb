module Authentication
  extend ActiveSupport::Concern

  included do
    # Resume first, and for every request. allow_unauthenticated_access skips
    # require_authentication, and without this line Current.user would be nil inside actions
    # that are open to guests but still care who is asking: a signed-in visitor creating a
    # hot-seat match would have been seated as a guest. require_authentication resumes as
    # well, and resume_session is idempotent, so nothing else changes.
    before_action :resume_session
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def authenticated?
      resume_session
    end

    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      Current.session ||= find_session_by_cookie
    end

    def find_session_by_cookie
      Session.find_by(id: cookies.signed[:session_id]) if cookies.signed[:session_id]
    end

    def request_authentication
      session[:return_to_after_authenticating] = request.url
      redirect_to new_session_path
    end

    def after_authentication_url
      session.delete(:return_to_after_authenticating) || root_url
    end

    def start_new_session_for(user)
      # Session fixation: whatever cookie session the visitor arrived with is thrown away at the
      # sign-in boundary, so a session id planted before sign in cannot be reused after it. The
      # generator did not do this. The only thing carried across is where the visitor was going.
      destination = session[:return_to_after_authenticating]
      reset_session
      session[:return_to_after_authenticating] = destination if destination

      # One transaction for the session row and the adoption of this browser's guest matches, so
      # a failure in either leaves neither: before this, a raise inside the adoption left the
      # row committed and the browser signed in without its games, which only a later sign-in
      # would have picked up (session-7 audit, finding L4).
      #
      # The cookie is written after the commit, on purpose. Written inside, a rollback would
      # leave the browser holding a signed cookie naming a session row that does not exist.
      created = Session.transaction do
        row = user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip)
        adopt_guest_matches(user)
        row
      end
      Current.session = created
      cookies.signed.permanent[:session_id] = { value: created.id, httponly: true, same_site: :lax }
      created
    end

    # Guest adoption (TASK-BRIEF 1.5, rubric 24). Every path into a signed-in session comes
    # through here, sign up and sign in alike, so this is the one place it can be done and the
    # one place it can be forgotten. It runs before the redirect, so the page the visitor lands
    # on already names them where it read Guest.
    #
    # The guest cookie is left as it is: it identifies the browser, not the match, and a second
    # sign-in from the same browser simply finds nothing left to adopt.
    def adopt_guest_matches(user)
      return if Current.guest_key.blank?

      adopted = Match.adopt_guest_matches(user: user, guest_key: Current.guest_key)
      Rails.logger.info("[adoption] #{adopted} guest matches adopted by user #{user.id}") if adopted.positive?
    end

    def terminate_session
      Current.session.destroy
      cookies.delete(:session_id)
      # Signing out empties the cookie session too, so nothing written while signed in (a flash,
      # a return-to, anything a later phase adds) survives into the signed-out browser.
      reset_session
    end
end
