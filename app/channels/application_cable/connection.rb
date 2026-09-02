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
  # Nothing here authorizes anything: a Turbo stream subscription is authorized by its signed
  # stream name, and the seat and turn rules of a match are enforced server-side on every action
  # that changes it.
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
