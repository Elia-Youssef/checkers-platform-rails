module ApplicationCable
  # Who is at the other end of a websocket.
  #
  # The generator wrote `set_current_user || reject_unauthorized_connection`, which closes the
  # socket for anyone without an account. This application is played by guests as well
  # (hot-seat and versus the computer need no account, TASK-BRIEF.md section 1.5) and a match
  # URL is readable by anyone, so refusing those connections would leave a guest or a viewer
  # with a page that silently never updates.
  #
  # A connection is therefore identified by the signed-in user when the session cookie resolves,
  # otherwise by the guest key from the signed guest cookie, otherwise as an anonymous viewer.
  #
  # Nothing here authorizes anything, it only says who is asking. Turbo signs a stream name so
  # that one cannot be forged, but a signed name is a claim and not a permission: which streams
  # a connection may have is decided on subscribe by MatchStreamAuthorization, which
  # config/initializers/match_stream_authorization.rb installs on Turbo::StreamsChannel itself,
  # and it decides by comparing the identity set below against the seat the name asks for. The
  # seat and turn rules of a match are enforced server-side on every action that changes it,
  # per request, never by membership of a socket.
  #
  # WHEN THIS IDENTITY SETTLES: here, once, at the handshake. Action Cable runs #connect when
  # the websocket opens, and the two identifiers keep the values it gives them for the life of
  # that socket; cookies that change afterwards never reach it. So a document that signed in
  # without a page load would go on asking as whoever it connected as, and would be refused
  # its seat's stream. That is why signing in, signing up and signing out are full page loads
  # (data-turbo="false" on the two forms and the sign-out button): ending the document ends the
  # socket, and the next one opens with the new cookies. Nothing is lost by the refusal in any
  # case, since no action is authorised by a subscription.
  class Connection < ActionCable::Connection::Base
    identified_by :current_user, :current_guest_key

    def connect
      self.current_user = user_from_session
      self.current_guest_key = cookies.signed[GuestIdentity::COOKIE_NAME]

      logger.add_tags(*connection_tags)
    end

    private
      def user_from_session
        Session.find_by(id: cookies.signed[:session_id])&.user
      end

      def connection_tags
        if current_user
          [ "ActionCable", "User #{current_user.id}" ]
        elsif current_guest_key
          [ "ActionCable", "Guest" ]
        else
          [ "ActionCable", "Viewer" ]
        end
      end
  end
end
