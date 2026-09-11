# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # While tests run files are not watched, reloading is not necessary.
  config.enable_reloading = false

  # Eager loading loads your entire application. When running a single test locally,
  # this is usually not necessary, and can slow down your test suite. However, it's
  # recommended that you enable it in continuous integration systems to ensure eager
  # loading is working properly before deploying your code.
  config.eager_load = ENV["CI"].present?

  # Configure public file server for tests with cache-control for performance.
  config.public_file_server.headers = { "cache-control" => "public, max-age=3600" }

  # Show full error reports.
  config.consider_all_requests_local = true

  # Rails generates :null_store here. The sign-in rate limit counts attempts in
  # Rails.cache and a null store makes every increment return nil, so the limit can never
  # fire and test/controllers/sign_in_rate_limit_test.rb could never see the 11th attempt
  # refused. test/test_helper.rb clears this store before every test so counters never leak
  # from one test into the next.
  config.cache_store = :memory_store

  # Render exception templates for rescuable exceptions and raise for other exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Disable request forgery protection in test environment.
  config.action_controller.allow_forgery_protection = false

  # Store uploaded files on the local file system in a temporary directory.

  # Tell Action Mailer not to deliver emails to the real world.
  # The :test delivery method accumulates sent emails in the
  # ActionMailer::Base.deliveries array.
  config.action_mailer.delivery_method = :test

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: "example.com" }

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true

  # YJIT on in the test environment as well as in development and production.
  #
  # Rails 8.1's load_defaults sets config.yjit = !Rails.env.local?, so the suite ran the plain
  # interpreter while the application ships on YJIT everywhere. That matters for one test:
  # ComputerPlayTest's "a Hard reply on the audit's worst reachable position answers inside the
  # budget" asserts RUBRIC item 10's three-second bound on the widest position two audits could
  # reach. With YJIT it measures 1.06 to 1.53 s, on 224,710 nodes at the same depth; the same
  # search on the plain interpreter measured 2.05 to 2.29 s in test/draughts_ai_check.rb
  # (and 2.19 to 2.66 s for this test when it was first measured, on another host, a margin of
  # 12 to 27 percent on a host this project has measured drifting 20 percent in a day and 42
  # percent in an afternoon). A red run should mean the shipped configuration missed the pin,
  # not that the suite was timing an interpreter nothing runs. Since Hard's floor deadline was
  # turned on (Draughts::AI::HARD_DEADLINE, 2.5 s), the interpreter also decides the depth this
  # test asserts: without YJIT that search is two to four tenths of a second from being cut off
  # at depth 7. The bound stays at 3.0 s and the test still prints what it measured.
  config.yjit = true

  # The computer opponent's random source. Every computer move draws uniformly at random
  # among the moves that scored equal, so games vary; a seed here makes that draw the same
  # one every run, which is what lets a test assert a particular Easy or Medium game. Hard
  # deepens against the wall clock as well, so a seed does not fix it and no test asserts a
  # particular Hard move (see lib/draughts/ai.rb).
  config.x.ai_random_seed = 20260902
end
