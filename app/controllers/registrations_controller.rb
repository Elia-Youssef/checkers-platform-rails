class RegistrationsController < ApplicationController
  allow_unauthenticated_access
  # The same ceiling as signing in, for the same reason: an unauthenticated POST that writes a
  # row. Ten a window is far more than a person needs (a sign-up is a once-in-a-lifetime form)
  # and it stops one client from filling the users table at HTTP speed; the round-1 audit made
  # twelve accounts in a few seconds from one client (finding L2). Keyed on the apparent client
  # alone, which is all there is to key on before an account exists: an attacker who varies
  # X-Forwarded-For gets a fresh counter, so this is a ceiling on accidents and on the lazy
  # case, not a defence against a distributed one. The refusal is shaped like the sign-in one,
  # a redirect back to the form with "Try again later.".
  rate_limit to: 10, within: 3.minutes, name: "sign-up-per-client", only: :create,
    with: -> { redirect_to new_registration_path, alert: "Try again later." }

  def new
    @user = User.new
  end

  def create
    @user = User.new(registration_params)

    if @user.save
      start_new_session_for @user
      redirect_to after_authentication_url, notice: "Welcome, #{@user.display_name}."
    else
      render :new, status: :unprocessable_content
    end
  end

  private
    def registration_params
      params.expect(user: [ :email_address, :display_name, :password, :password_confirmation ])
    end
end
