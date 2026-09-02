Rails.application.routes.draw do
  # Identity: the Rails 8 authentication generator's session and password reset routes,
  # plus sign up.
  resource :session
  resource :registration, only: %i[ new create ]
  resources :passwords, param: :token

  # Matches. The board is server state: /matches/:id?selected=11 renders that piece's legal
  # targets, one POST to .../moves plays one leg of a move, and the confirmation step for a
  # resignation is a page of its own so that resigning needs no JavaScript.
  resources :matches, only: %i[ create show ] do
    resources :moves, only: :create
    resource :undo, only: :create
    resource :resignation, only: %i[ new create ]
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # The home page: the four ways to play.
  root "home#index"
end
