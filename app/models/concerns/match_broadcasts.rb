# How a match reaches the browsers that are watching it.
#
# After every accepted action a match renders itself and pushes the result over Turbo Streams
# through Action Cable (Solid Cable) so that every other open page updates within two seconds
# without a reload. The acting browser does not depend on this: its own response already
# carries the same fragments, which is why the game still plays with JavaScript switched off.
#
# ---------------------------------------------------------------------------------------
# ONE STREAM PER AUDIENCE, because a fragment is not the same for everyone.
#
# The board is playable for the seat whose turn it is and dead for everyone else; the controls
# hold Resign, Offer draw and, on a finished match, the rematch invite link. Broadcasting one
# rendering to one shared stream would therefore either take the acting player's board away or
# hand a viewer somebody else's controls, and the rematch link on a shared stream would give
# every viewer of a finished match a token that lets them take a seat in the next one.
#
# So an online match broadcasts three renderings, to three streams:
#
#   [match, "red"]      rendered for the holder of the Red seat
#   [match, "white"]    rendered for the holder of the White seat
#   [match, "viewer"]   rendered for anybody else: a dead board, no controls, the viewing note
#
# A hot-seat or computer match has only viewers to inform (the one browser that plays it gets
# every update in its own response), so it broadcasts the viewer rendering alone.
#
# Turbo signs a stream name with the application's secret before it reaches the page, and the
# seat streams are only ever named inside the seat holder's own HTML, so a viewer never sees
# one and cannot forge it; MatchStreamAuthorization then refuses a seat's stream to any
# connection but that seat holder's, so a name read off somebody's screen is no longer a key.
# Nothing is authorised by socket membership all the same; every action is authorised per
# request by MatchScoped.
#
# WHO SUBSCRIBES. A page subscribes only when somebody other than this browser can change the
# match: the holder of one seat in an online match, or a viewer. The hot-seat browser holds
# both seats and the human in a computer match is the only actor there (the computer replies
# inside the human's own request), so those pages subscribe to nothing and can never have a
# selection clobbered by an echo of their own move.
#
# RENDERED OUTSIDE A REQUEST. These partials run in ApplicationController.render, where there
# is no session, no cookies, no Current and no request. Everything they need is passed as a
# local. Two consequences worth knowing:
#   - forms rendered here carry no authenticity token (Rails omits it when the session is
#     disabled). Turbo sends the token from the page's own csrf-token meta tag in the
#     X-CSRF-Token header, which is what Rails checks first, so a control that arrived by
#     broadcast still submits. With JavaScript off there are no broadcasts at all and every
#     form on the page came from a real request.
#   - _url helpers have no host here, so broadcast fragments use path helpers only.
module MatchBroadcasts
  extend ActiveSupport::Concern

  # The three ways a match can look. "viewer" is also the audience of a hot-seat or computer
  # match, which nobody else can act in.
  AUDIENCES = %w[ red white viewer ].freeze
  VIEWER = "viewer"

  # The streamables Turbo signs: this match, the audience, and, for a seat, the user who holds
  # that seat.
  #
  # The user is in the name because a signed stream name is a bearer token: whoever holds it
  # receives that audience's fragments for as long as the socket lives. Keyed by colour alone, a
  # name handed to the Red seat kept delivering Red's controls (and, after Play again, Red's
  # rematch invite token) to whoever still had it, whatever had happened to the seat since
  # (session-6 audit, finding M2). Including the seat's user means a name is dead the moment the
  # seat is held by somebody else.
  #
  # The name alone is no longer enough to listen, which it used to be: a signed name is page
  # content, and the round-1 audit handed one to a websocket carrying no cookies at all, was
  # accepted, and collected the rematch invite token off the Red seat's stream (finding M2).
  # MatchStreamAuthorization now checks the claim on subscribe, so a seat stream is delivered
  # only to a connection whose signed-in user is the user in the name; the viewer stream stays
  # open to anybody, because its rendering is the read-only board any visitor can already fetch.
  # Nothing here changed for that: the names are the same and so are the broadcasts.
  def stream_for(audience)
    audience = audience.to_s
    return [ self, audience ] if audience == VIEWER

    [ self, audience, seat_user(audience) ].compact
  end

  # The audiences this match renders for. Only an online match has two players to tell apart.
  def broadcast_audiences
    online? ? AUDIENCES : [ VIEWER ]
  end

  # The seats an audience holds, which is what the partials branch on.
  def audience_seats(audience)
    audience.to_s == VIEWER ? [] : [ audience.to_s ]
  end

  # The stream a page showing this match to these seats should subscribe to, or nil when this
  # browser is the only actor and an echo of its own move would be all it ever received.
  def live_audience(seats)
    seats = Array(seats).map(&:to_s)
    return VIEWER if seats.empty?
    return seats.first if online? && seats.length == 1

    nil
  end

  # The key of the silence flag below, in Rails' own per-thread (and per-fiber) store.
  SILENCE_KEY = :match_broadcasts_silenced

  class_methods do
    # Runs the block with broadcasting off. db/seeds.rb replays a whole game through the same
    # public move path the application uses, and every leg of it would otherwise render the
    # match three times and write a Solid Cable row for an audience that does not exist: about
    # a second of work per seeded game, in a script that has no browsers listening. Nothing
    # else uses this, the default is off, and it is per thread, so one Puma thread cannot
    # silence another's broadcasts.
    def silence_broadcasts
      previous = ActiveSupport::IsolatedExecutionState[SILENCE_KEY]
      ActiveSupport::IsolatedExecutionState[SILENCE_KEY] = true
      yield
    ensure
      ActiveSupport::IsolatedExecutionState[SILENCE_KEY] = previous
    end

    def broadcasts_silenced?
      ActiveSupport::IsolatedExecutionState[SILENCE_KEY] == true
    end
  end

  # Render this match once per audience and push it. Called by every transition after its
  # transaction has committed, so nothing is ever broadcast for a write that rolled back.
  #
  # The game is restored once and handed to all three renderings: it is the same board for
  # everyone, and only the seat the rendering is for changes.
  def broadcast_state!
    return self unless persisted?
    return self if self.class.broadcasts_silenced?

    current = game
    broadcast_audiences.each do |audience|
      Turbo::StreamsChannel.broadcast_render_to(
        *stream_for(audience),
        partial: "matches/live",
        locals: { match: self, game: current, seats: audience_seats(audience) })
    end
    self
  end
end
