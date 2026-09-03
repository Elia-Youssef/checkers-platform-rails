require "test_helper"
require Rails.root.join("lib/tasks/database_notice")

# The reminder that db:reset and db:drop print in development when the server is still up.
#
# lib/tasks/development_database.rake hangs this on both tasks, and only in development, so
# what is worth pinning is the condition itself: the notice appears when the server's pid file
# is there and stays quiet when it is not. A refusal would be wrong (a pid file left behind by
# a killed container must not stop a reset), so nothing here asserts that anything is blocked.
# Round-2 adoption audit, finding M1.
class DatabaseNoticeTest < ActiveSupport::TestCase
  def setup
    DatabaseNotice.reset!
  end

  def teardown
    DatabaseNotice.reset!
  end

  # A throwaway root holding a pid file, or not holding one.
  def with_root(server_running:)
    Dir.mktmpdir do |root|
      if server_running
        FileUtils.mkdir_p(File.join(root, "tmp/pids"))
        File.write(File.join(root, DatabaseNotice::PID_PATH), "1\n")
      end
      yield root
    end
  end

  test "there is a notice when the server's pid file is there" do
    with_root(server_running: true) do |root|
      notice = DatabaseNotice.message(root)

      assert_not_nil notice
      assert_includes notice, "The development server is still running"
      assert_includes notice, "docker compose restart web"
    end
  end

  test "there is no notice when no server is running" do
    with_root(server_running: false) do |root|
      assert_nil DatabaseNotice.message(root)
    end
  end

  test "the notice is printed once, however many tasks ask for it" do
    with_root(server_running: true) do |root|
      out = StringIO.new

      assert DatabaseNotice.announce(root, out), "db:drop asks for it"
      assert_not DatabaseNotice.announce(root, out), "db:reset asks for it too"
      assert_equal 1, out.string.scan("The development server is still running").length
    end
  end

  test "nothing is printed when no server is running" do
    with_root(server_running: false) do |root|
      out = StringIO.new

      assert_not DatabaseNotice.announce(root, out)
      assert_empty out.string
    end
  end

  test "the pid file is looked for where compose keeps it" do
    assert_equal "tmp/pids/server.pid", DatabaseNotice::PID_PATH
  end
end
