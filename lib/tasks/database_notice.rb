# The notice printed after a development db:reset or db:drop while the server is running.
#
# `docker compose run --rm web bin/rails db:reset` deletes storage/development.sqlite3 and
# writes a new one from a one-off container, while the `docker compose up` container is still
# serving. Its Puma workers keep their open file descriptors on the deleted file, so they go
# on reading and writing an inode that is no longer on disk: the pages show the games that
# were there before the reset, and every row written after it disappears at the next restart,
# with no error anywhere. Measured in the round-2 adoption audit, finding M1.
#
# The signal that this has happened is the server's own pid file. tmp/ is a named volume
# shared by the server container and every `docker compose run` container (compose.yaml), so
# a one-off process can see it.
#
# A notice, not a refusal: a pid file left behind by a container that was killed must never
# stop anyone resetting their database, and the reset itself is unchanged either way. Plain
# Ruby with no Rails constant in it, so the condition can be tested without rake.
#
# lib/tasks is outside the autoload paths (config.autoload_lib ignores it), so this file is
# reached by an explicit require, from lib/tasks/development_database.rake and from its test.
module DatabaseNotice
  PID_PATH = "tmp/pids/server.pid"

  MESSAGE = <<~TEXT.freeze
    ==> The development server is still running, and it is still holding the database file
        that was just deleted (#{PID_PATH} exists). Its Puma workers will go on serving the
        old data, and anything written to them will be gone at the next restart. Restart it:

            docker compose restart web

        Or stop the stack first next time: docker compose down, then the reset, then up.
  TEXT

  class << self
    # The notice, or nil when the server is not running. root is the Rails root.
    def message(root)
      File.exist?(File.join(root.to_s, PID_PATH)) ? MESSAGE : nil
    end

    # Prints the notice at most once in a process. Answers whether it printed.
    def announce(root, out = $stdout)
      text = message(root)
      return false if text.nil? || @announced

      @announced = true
      out.puts(text)
      true
    end

    # Asks for the notice when the command finishes, so that it is the last thing on screen
    # rather than a line in the middle of the output: db:reset invokes db:drop before it
    # creates and seeds the new database, so a notice printed the moment the file went would
    # scroll away under the lines that follow it.
    def announce_at_exit(root, out = $stdout)
      return false if @scheduled

      @scheduled = true
      at_exit { announce(root, out) }
      true
    end

    # For the test: forget what has already been said.
    def reset!
      @announced = false
      @scheduled = false
    end
  end
end
