ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "test_helpers/session_test_helper"
require_relative "test_helpers/cookie_test_helper"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers.
    #
    # Rails generates :number_of_processors, which is 32 here, and every worker forks and
    # builds its own copy of both SQLite databases. Measured on this suite inside the
    # container: 1 worker 9.2 s, 4 workers 4.4 s, 8 workers 4.5 s, 32 workers 4.7 s and
    # 29 s of CPU. Four it is; PARALLEL_WORKERS overrides it without editing this file.
    parallelize(workers: Integer(ENV.fetch("PARALLEL_WORKERS", 4)))

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # The sign-in rate limit counts attempts in Rails.cache, which is a real memory store
    # in the test environment. Clear it before every test so one test's attempts cannot
    # rate limit the next test that runs in the same worker process.
    setup { Rails.cache.clear }

    # Add more helper methods to be used by all tests here...
  end
end

# The engine suite runs here too.
#
# test/draughts/**/*_test.rb are plain Minitest tests (not ActiveSupport::TestCase) that
# require "draughts" from lib, which Rails keeps on $LOAD_PATH, so bin/rails test runs all 230
# of them with the whole framework loaded. That is a different environment from the Rails-free
# runner and can catch, for example, a gem that redefines something the engine relies on. They
# take no part in the fixtures, the database or the parallel workers above.
#
# Nothing about them is skipped or filtered here. One assertion inside
# DraughtsAITest#test_the_ai_files_require_nothing_but_each_other only makes sense in a process
# without Rails and carries its own `unless defined?(Rails)` guard; the Rails-free runner is
# where that claim is really checked, before the requires and again after the suite.
