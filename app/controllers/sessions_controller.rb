class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  # Two limits, both 10 attempts per 3 minutes. The generator's is keyed on the client address,
  # which an attacker controls whenever a proxy header is trusted: varying X-Forwarded-For gave
  # every attempt its own counter and eleven wrong passwords all went through. The second is
  # keyed on the account being attacked, so one address cannot be guessed more than ten times in
  # the window whatever the headers say. Both need a name once there is more than one.
  rate_limit to: 10, within: 3.minutes, name: "sign-in-per-client", only: :create,
    with: -> { redirect_to new_session_path, alert: "Try again later." }
  rate_limit to: 10, within: 3.minutes, name: "sign-in-per-account", only: :create,
    by: -> { params[:email_address].to_s.strip.downcase },
    with: -> { redirect_to new_session_path, alert: "Try again later." }

  def new
  end

  def create
    if user = authenticate_by_credentials
      start_new_session_for user
      redirect_to after_authentication_url
    else
      redirect_to new_session_path, alert: "Try another email address or password."
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other
  end

  private
    # Only scalar credentials can be a sign-in attempt. A forged form can send an array or a
    # hash, strong parameters drop it, and User.authenticate_by then raises ArgumentError for the
    # missing key: an unauthenticated 500. This is a failed attempt like any other, it redirects
    # with the usual alert, and both rate limits have already counted it before this runs.
    #
    # Reading the two values directly also keeps the sign-in log clean: permit would report the
    # CSRF field that rides along in the same params hash as an unpermitted parameter.
    def authenticate_by_credentials
      email_address, password = params[:email_address], params[:password]
      return nil unless email_address.is_a?(String) && password.is_a?(String)

      User.authenticate_by(email_address: email_address, password: password)
    end
end
