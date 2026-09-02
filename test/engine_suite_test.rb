require "test_helper"

# The boundary between the two halves of this project, checked from the Rails side.
#
# The Draughts engine is plain Ruby under lib/draughts with its own require graph. It is
# excluded from Zeitwerk (config/application.rb) and required by name
# (config/initializers/draughts.rb), and its own test files run inside bin/rails test as
# well as inside the Rails-free runner. This file proves that arrangement rather than
# describing it.
class EngineSuiteTest < ActiveSupport::TestCase
  ENGINE_TEST_CLASS_PATTERN = /\A(Draughts|JavaPort)/

  def engine_test_classes
    Minitest::Runnable.runnables.select { |runnable| runnable.name.to_s.match?(ENGINE_TEST_CLASS_PATTERN) }
  end

  test "lib is on the load path, so require draughts resolves inside Rails" do
    assert_includes $LOAD_PATH, Rails.root.join("lib").to_s
    assert_equal Rails.root.join("lib/draughts.rb").to_s, $LOADED_FEATURES.grep(%r{/lib/draughts\.rb\z}).first
  end

  test "the engine is loaded and answers for itself" do
    assert defined?(Draughts::PDN), "Draughts::PDN is missing: the explicit require did not run"
    assert defined?(Draughts::AI), "Draughts::AI is missing: the explicit require did not run"
    assert_equal "rrrrrrrrrrrr--------wwwwwwwwwwww", Draughts::Position.start.board_string
    assert_equal 7, Draughts::Rules.legal_moves(Draughts::Position.start).length
  end

  test "the engine is ignored by Zeitwerk while the rest of lib is not" do
    loader = Rails.autoloaders.main

    assert_includes loader.dirs, Rails.root.join("lib").to_s
    # cpath_expected_at returns the constant Zeitwerk would define for a file, or nil when
    # the file is ignored. lib/draughts/pdn.rb would be Draughts::Pdn, which is not what
    # the engine defines, so the whole directory is ignored and required by hand instead.
    assert_nil loader.cpath_expected_at(Rails.root.join("lib/draughts/pdn.rb").to_s)
    assert_nil loader.cpath_expected_at(Rails.root.join("lib/draughts/ai.rb").to_s)
    assert_equal "User", loader.cpath_expected_at(Rails.root.join("app/models/user.rb").to_s)

    assert defined?(Draughts::PDN)
    assert_not Draughts.const_defined?(:Pdn, false)
  end

  # bin/rails test loads test/**/*_test.rb minus test/{system,dummy,fixtures}/**, so the
  # engine's own files are in the default run. This holds however the runner was invoked,
  # which the two tests after it cannot: they need the engine files to have been loaded, and
  # `bin/rails test test/engine_suite_test.rb` loads this file alone.
  test "the default test glob picks up the engine test files" do
    files = Dir.glob(Rails.root.join("test/**/*_test.rb").to_s)
    engine_files = files.grep(%r{/test/draughts/})

    assert_equal 17, engine_files.length, "expected 17 engine test files under test/draughts"
    assert_empty engine_files.grep(%r{/test/(system|dummy|fixtures)/}),
      "an engine test file sits in a directory the Rails runner excludes"
  end

  test "the engine tests run here when the whole suite runs" do
    skip "this run was filtered to single files" unless defined?(DraughtsAITest)

    engine_tests = engine_test_classes.sum { |klass| klass.runnable_methods.length }
    assert_operator engine_tests, :>=, 230,
      "expected the 230 engine tests to run here as well, counted #{engine_tests}"
  end

  test "no engine test is skipped or filtered by the Rails runner" do
    skip "this run was filtered to single files" unless defined?(DraughtsAITest)

    # The only skip the engine suite carries is its own: the slow perft depths behind
    # DRAUGHTS_SLOW. Anything else skipped here would mean the Rails run is quietly smaller
    # than the Rails-free run.
    assert_includes DraughtsAITest.runnable_methods, "test_the_ai_files_require_nothing_but_each_other"
    assert_not defined?(SkipEngineTestsThatAssertRailsIsAbsent),
      "an engine test is being skipped by name under bin/rails test"
  end
end
