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
    # Online only. Every one is a plain POST from a plain form, so the whole online flow
    # (cancel a waiting match, offer a draw, answer it, ask for a rematch) works with
    # JavaScript switched off, and every one is authorised by the seat rule in MatchScoped.
    resource :cancellation, only: :create
    resource :rematch, only: :create
    post "draw/offer" => "draw_offers#create", as: :draw_offer
    post "draw/accept" => "draw_offers#accept", as: :draw_accept
    post "draw/decline" => "draw_offers#decline", as: :draw_decline
  end

  # The invite link. Opening it while signed in takes the free seat and starts the match,
  # which is what makes the link one click for the person who was sent it; the page it lands
  # on is the match itself. /join on its own is where a pasted link or bare token is turned
  # into one of these addresses.
  get "join" => "joins#new", as: :new_join
  post "join" => "joins#create", as: :joins
  get "join/:token" => "joins#show", as: :join

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # The home page: the four ways to play.
  root "home#index"
end
