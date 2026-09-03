# The invite link.
#
#   GET  /join            paste a link or a token
#   POST /join            turn what was pasted into /join/:token
#   GET  /join/:token     take the free seat and start the match
#
# The seat is taken by opening the link, so being invited is one click. That makes a GET
# change state, which is deliberate and bounded: the token is single use, the only person it
# can seat is the signed-in visitor who opened it, opening it twice is refused with a notice
# rather than doing anything again, and Turbo's prefetch-on-hover is switched off for the
# whole application in the layout so that no link is ever followed by accident.
#
# Signing in is required first, and the sign-in page comes back here afterwards
# (Authentication#request_authentication stores this URL), so an invited visitor who has no
# account yet signs up, returns, and lands in the match.
class JoinsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]

  # A ceiling on the endpoint, not a defence against guessing: a token is 192 bits of
  # SecureRandom and there is no timing oracle, so nobody is finding one by trying. What this
  # bounds is a client hitting the database once per request without limit (the session-6 audit
  # measured 60 wrong tokens in 1.26 s, finding M3). A person opens an invite link a handful of
  # times, so the number is generous on purpose and no honest flow, and no test or probe burst,
  # comes near it.
  #
  # Two keys, for the reason the sign-in limits have two. The first is the apparent client
  # address, which this application takes from X-Forwarded-For (trusted_proxies is unset, see
  # README, "The production image"), so a client that varies the header gets a fresh counter
  # every request: the session-6 diff review measured a 130-token sweep passing untouched that
  # way. The second is the identity behind the request, which nobody can vary without signing in
  # as somebody else: a signed-in user is their own id, a visitor with no account is their signed
  # guest cookie, and only a request carrying neither falls back to the address. Both concerns
  # run after Authentication and GuestIdentity, so Current is set by the time the key is read.
  JOIN_ATTEMPTS = 120
  JOIN_WINDOW = 1.minute
  rate_limit to: JOIN_ATTEMPTS, within: JOIN_WINDOW, name: "join-per-client",
    only: %i[ show create ],
    with: -> { redirect_to new_join_path, status: :see_other, alert: "Too many attempts. Try again in a minute." }
  rate_limit to: JOIN_ATTEMPTS, within: JOIN_WINDOW, name: "join-per-identity",
    only: %i[ show create ],
    by: -> { Current.user&.id || Current.guest_key || request.remote_ip },
    with: -> { redirect_to new_join_path, status: :see_other, alert: "Too many attempts. Try again in a minute." }

  def new
    @invite = params[:invite].to_s
  end

  # A full invite link, or a bare token, or something else entirely.
  def create
    token = self.class.token_from(params[:invite])
    if token
      redirect_to join_path(token)
    else
      redirect_to new_join_path, status: :see_other,
        alert: "That does not look like an invite link. Paste the whole address, or just the code at the end of it."
    end
  end

  # Taking the seat is Match#join!'s decision and nobody else's: it asks Match#join_refusal
  # again inside the transaction that writes, so there is no gap between deciding that the link
  # is open and using it. This action only reports the answer. A check here before the call
  # would be exactly that gap, and two people opening a forwarded link at the same moment both
  # passed it (session-6 audit, finding C1).
  def show
    match = Match.find_by(invite_token: params[:token])

    return refuse(nil, "That invite link is not valid.") if match.nil?
    return seated_already(match) if match.seats_held_by(user: Current.user).any?

    match.join!(Current.user)
    redirect_to match_path(match), status: :see_other, notice: "You joined this match as #{joined_side(match)}."
  rescue Draughts::Error
    # Refused: the link was spent, the match had moved on, or somebody else took the seat in
    # the moment between this page being opened and this click. Whoever holds the seats now is
    # right; this visitor is a viewer and is told so on the board they were heading for.
    match.reload
    return seated_already(match) if match.seats_held_by(user: Current.user).any?

    refuse(match, "That invite link is #{closed_reason(match)}.")
  end

  # The token inside whatever was pasted: a whole invite address, an address with a query
  # string on it, or the token by itself. Anything else is nil.
  def self.token_from(value)
    text = value.to_s.strip
    return nil if text.empty?

    text = text.split(/[?#]/).first.to_s
    candidate = text.split("/").last.to_s
    candidate if candidate.length >= Match::MINIMUM_TOKEN_LENGTH && Match::TOKEN_FORMAT.match?(candidate)
  end

  private
    # The creator opening their own link, and anybody who has already joined: both are told
    # what happened and sent to the match, which is where they wanted to be anyway.
    def seated_already(match)
      notice =
        if match.waiting?
          "You created this match. Send the invite link to the player you want to join you."
        else
          "You are already playing in this match."
        end
      redirect_to match_path(match), status: :see_other, notice: notice
    end

    def closed_reason(match)
      return "no longer open: the match was cancelled" if match.cancelled?
      return "no longer open: this match has already finished" if match.finished?

      "no longer open: somebody has already taken the free seat"
    end

    def joined_side(match)
      Match::SIDES.find { |side| match.seat_held_by?(side, user: Current.user) }&.capitalize
    end

    def refuse(match, message)
      redirect_to((match ? match_path(match) : root_path), status: :see_other, alert: message)
    end
end
