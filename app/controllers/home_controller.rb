class HomeController < ApplicationController
  allow_unauthenticated_access only: :index

  # The four ways to play. Phases 4 to 6 replace the placeholder controls in each section
  # with the real create forms; the sections and their ids are here so that the layout,
  # the tokens and the navigation are settled first.
  def index
  end
end
