class PasswordsController < ApplicationController
  allow_unauthenticated_access
  before_action :set_user_by_token, only: %i[ edit update ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_password_path, alert: "Try again later." }

  def new
  end

  def create
    if user = User.find_by(email_address: params[:email_address])
      PasswordsMailer.reset(user).deliver_later
    end

    redirect_to new_session_path, notice: "Password reset instructions sent (if user with that email address exists)."
  end

  def edit
  end

  def update
    @user.assign_attributes(new_password)

    if @user.save(context: :password_reset)
      @user.sessions.destroy_all
      redirect_to new_session_path, notice: "Password has been reset."
    else
      render :edit, status: :unprocessable_content
    end
  end

  private
    # Only a String can be a new password. A parameter shaped as an array or a hash
    # (password[]=x) is not one, and passing it on would only make strong parameters drop it and
    # log noise; leaving it out means `password` stays unset and the :password_reset validation
    # refuses the reset. The two keys are literal, so there is no mass-assignment surface here.
    def new_password
      %i[ password password_confirmation ].filter_map { |key|
        [ key, params[key] ] if params[key].is_a?(String)
      }.to_h
    end

    def set_user_by_token
      @user = User.find_by_password_reset_token!(params[:token])
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      redirect_to new_password_path, alert: "Password reset link is invalid or has expired."
    end
end
