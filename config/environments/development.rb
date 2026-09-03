require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Make code changes take effect immediately without server restart.
  config.enable_reloading = true

  # Do not eager load code on boot.
  config.eager_load = false

  # Show full error reports.
  config.consider_all_requests_local = true

  # Enable server timing.
  config.server_timing = true

  # Enable/disable Action Controller caching. By default Action Controller caching is disabled.
  # Run rails dev:cache to toggle Action Controller caching.
  if Rails.root.join("tmp/caching-dev.txt").exist?
    config.action_controller.perform_caching = true
    config.action_controller.enable_fragment_cache_logging = true
    config.public_file_server.headers = { "cache-control" => "public, max-age=#{2.days.to_i}" }
  else
    config.action_controller.perform_caching = false
  end

  # Change to :null_store to avoid any caching.
  # Keep a real store: ActionController::RateLimiting counts sign-in attempts in
  # Rails.cache, and with :null_store every increment returns nil, which silently turns
  # the rate limit in SessionsController off. See test/controllers/sign_in_rate_limit_test.rb.
  #
  # Solid Cache rather than :memory_store, and the same store production uses: the
  # development server runs WEB_CONCURRENCY Puma workers (compose.yaml), and a memory store
  # lives in one process, so each worker would keep its own copy of those counters and ten
  # attempts per three minutes would silently become ten per worker. The counters live in
  # storage/development_cache.sqlite3 (config/cache.yml and config/database.yml), which every
  # worker shares.
  config.cache_store = :solid_cache_store

  # Store uploaded files on the local file system (see config/storage.yml for options).

  # Don't care if the mailer can't send.
  config.action_mailer.raise_delivery_errors = false

  # Make template changes take effect immediately.
  config.action_mailer.perform_caching = false

  # Set localhost to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: "localhost", port: 3000 }

  # Print deprecation notices to the Rails logger.
  config.active_support.deprecation = :log

  # Raise an error on page load if there are pending migrations.
  config.active_record.migration_error = :page_load

  # Highlight code that triggered database queries in logs.
  config.active_record.verbose_query_logs = true

  # Append comments with runtime information tags to SQL queries in logs.
  config.active_record.query_log_tags_enabled = true

  # Highlight code that enqueued background job in logs.
  config.active_job.verbose_enqueue_logs = true

  # Highlight code that triggered redirect in logs.
  config.action_dispatch.verbose_redirect_logs = true

  # Suppress logger output for asset requests.
  config.assets.quiet = true

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  config.action_view.annotate_rendered_view_with_filenames = true

  # Action Cable's forgery protection stays on. Rails' development default allows
  # http(s)://localhost:<port> plus anything whose Origin equals the host it was sent to
  # (config.action_cable.allow_same_origin_as_host, true by default), so a browser at
  # http://127.0.0.1:3000 already works. These two patterns add the mixed cases, where a page
  # loaded from one spelling of the loopback address opens a socket to the other, so a reviewer
  # who reaches the application by IP literal never loses the live board. Production keeps the
  # strict default: only the origins it is configured for.
  config.action_cable.allowed_request_origins = [
    %r{\Ahttps?://localhost(:\d+)?\z},
    %r{\Ahttps?://127\.0\.0\.1(:\d+)?\z}
  ]

  # YJIT on in development as well as in production.
  #
  # Rails 8.1's load_defaults sets config.yjit = !Rails.env.local?, so development and test run
  # the plain interpreter while production runs YJIT. That makes every development timing
  # measurement a measurement of a slower machine than the one the application ships on, and
  # the computer opponent is the one part of this application where that matters: the
  # depth-8 floor on the audits' worst reachable position takes 2.53 s of pure Ruby without
  # YJIT and 1.27 s with it, on the same 224,800 nodes. Item 10's three-second budget is
  # measured in development, so development should measure what production does.
  config.yjit = true

  # Watch the source tree from a background thread instead of from inside every request.
  #
  # The default here is ActiveSupport::FileUpdateChecker, which on every single request globs
  # ten directory trees (lib, app/models, app/controllers and the rest) and stats every file it
  # finds. On a Docker bind mount from a Windows host that cost 100 to 320 ms of every request,
  # measured, which was more than this application's controller actions take and, on a request
  # that also runs a Hard search, was the difference between comfortably inside the three second
  # budget and over it. EventedFileUpdateChecker (the listen gem, development group only) moves
  # all of that to a background thread and leaves the request path reading one boolean.
  #
  # Docker Desktop on Windows does not deliver inotify events for edits made on the host, so
  # compose.yaml sets LISTEN_FORCE_POLLING and config/initializers/file_watching.rb turns
  # listen's inotify backend off: listen then polls from its own thread, which is the same work
  # as before but off the request path, where a filesystem stall no longer delays a request.
  # On a host that does propagate inotify, leave the variable unset.
  config.file_watcher = ActiveSupport::EventedFileUpdateChecker

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true

  # Apply autocorrection by RuboCop to files generated by `bin/rails generate`.
  # config.generators.apply_rubocop_autocorrect_after_generate!

  # No seed: every computer move draws from a fresh random source, so two games against the
  # same level differ. The test environment pins a seed instead. An unset config.x key answers
  # with an empty OrderedOptions rather than nil, so this is set explicitly.
  config.x.ai_random_seed = nil
end
