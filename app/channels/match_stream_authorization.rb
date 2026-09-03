# Who may subscribe to a match's Turbo stream.
#
# An online match broadcasts one rendering per audience (MatchBroadcasts): the Red seat, the
# White seat and everybody else. The seat renderings carry that seat's controls and, after
# Play again, the invite token of the rematch, so a seat stream must reach that seat's player
# and nobody else.
#
# Turbo signs a stream name with the application's secret and refuses one it did not sign, so
# a name cannot be forged or guessed. That is not enough on its own: a signed name is written
# into the seat holder's own page, and until this guard existed a websocket presenting that
# string with no cookies at all was accepted and received everything the seat received. The
# round-1 audit reproduced the whole chain (finding M2): an unauthenticated socket holding the
# Red seat's name collected the rematch invite token and a third user used it to take the seat.
# Possession of the name was access.
#
# So the name is a claim and this is where it is checked, on subscribe:
#
#   [match, "viewer"]           anybody, including a socket with no cookies. The viewer
#                               rendering is a dead board, a move list and a viewing note:
#                               exactly what any visitor can already fetch by opening the
#                               match page, so there is nothing to withhold.
#   [match, "red", user]        only a connection whose signed-in user is that user, and only
#   [match, "white", user]      while that user still holds that seat. A connection with no
#                               identity, a guest, or the other seat's player is rejected.
#   anything else               rejected. These are the only streams this application
#                               broadcasts to, so the rule is an allow-list and not a filter.
#
# The check is a re-derivation, not a parse of trusted input: the name has already been
# verified against the application's secret before it reaches here, its three parts are
# GlobalID parameters (URL-safe Base64, which cannot contain the ":" separator) and a fixed
# audience word, and each part is turned back into the record it names before it is compared.
#
# WHERE IT IS INSTALLED. On Turbo::StreamsChannel itself, by
# config/initializers/match_stream_authorization.rb, and therefore on every subclass of it as
# well. A guard on a channel of our own would have left the hole open: the channel a
# subscription runs through is named by the client, so a socket can always ask for
# Turbo::StreamsChannel whatever the page says (the audit's own probe does exactly that), and
# only a rule the base channel enforces can refuse it. Measured both ways: with the guard on a
# subclass alone, the same seat name presented as Turbo::StreamsChannel was still confirmed.
#
# WHAT IT DOES NOT DO. Action Cable settles the identity of a socket when the socket opens, so
# this binds a subscription to who the connection was at its handshake. A page that subscribes
# after its visitor has signed out of another tab keeps the seat it had until the socket is
# replaced, and a browser that signed in without a full page load carries the identity it
# connected with (see the note in ApplicationCable::Connection). Nothing is authorised by
# socket membership in any case: every action that changes a match is authorised per request
# against the seat, and answers 403 to a session that holds none.
module MatchStreamAuthorization
  extend ActiveSupport::Concern

  included do
    before_subscribe :authorize_match_stream
  end

  private
    # Runs before the channel's own #subscribed. Rejecting and then aborting the callback
    # chain means the channel never reaches stream_from, so a refused socket is never
    # subscribed to the stream for even one message.
    def authorize_match_stream
      name = self.class.verified_stream_name(params[:signed_stream_name])
      # An unsigned, altered or absent name: the channel itself rejects it, and it is not this
      # guard's business to decide what a name nobody signed was meant to be.
      return if name.blank?
      return if match_stream_permitted?(name)

      reject
      throw :abort
    end

    def match_stream_permitted?(name)
      match_param, audience, seat_param, extra = name.split(":")
      return false unless extra.nil? && MatchBroadcasts::AUDIENCES.include?(audience)
      return seat_param.nil? if audience == MatchBroadcasts::VIEWER
      return false unless seat_param && current_user

      match = locate(match_param, Match)
      match.present? &&
        locate(seat_param, User) == current_user &&
        match.seat_user(audience) == current_user
    end

    # The record a GlobalID parameter names, or nil when it names none of ours. Locating is
    # what makes the comparison above a comparison of records rather than of strings.
    def locate(gid_param, klass)
      GlobalID::Locator.locate(gid_param, only: klass)
    rescue ActiveRecord::RecordNotFound, NameError
      nil
    end
end
