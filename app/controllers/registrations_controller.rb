class RegistrationsController < ApplicationController
  allow_unauthenticated_access

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
