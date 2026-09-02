require_relative "boot"

# The frameworks this application uses, named one by one instead of `require "rails/all"`.
# Active Storage, Action Mailbox and Action Text are deliberately absent: nothing here uploads
# a file, receives mail or edits rich text, and rails/all mounted 13 Active Storage routes and
# 6 Action Mailbox ingress routes that were attack surface with no purpose (session-4 audit,
# finding L5). Active Job stays because Action Mailer's deliver_later and Solid Queue need it;
# Action Mailer stays for the password reset; Action Cable stays for the live board of phase 6.
require "rails"

require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_view/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Checkers
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    #
    # `draughts` is ignored on purpose. lib/draughts is the pure-Ruby rules engine: it has
    # its own require graph (lib/draughts.rb requires every file in dependency order), it
    # must keep running in a plain Ruby process with no Rails loaded, and two of its
    # constants (Draughts::PDN and Draughts::AI) do not match the file names pdn.rb and
    # ai.rb under Zeitwerk's default inflector. config/initializers/draughts.rb requires it
    # explicitly instead. Rails still puts lib on $LOAD_PATH (config.paths has
    # `lib` with load_path: true), which is what makes `require "draughts"` resolve here
    # and in the engine's own tests.
    config.autoload_lib(ignore: %w[assets tasks draughts])

    # Forms render their own error markup (a message under the field and an invalid
    # modifier on its wrapper), so Rails does not need to wrap the input in a
    # div.field_with_errors that would break the field layout.
    config.action_view.field_error_proc = ->(html_tag, _instance) { html_tag }

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
