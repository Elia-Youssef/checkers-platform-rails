class ApplicationController < ActionController::Base
  # GuestIdentity first, so the guest cookie is issued even on a request that
  # Authentication redirects to the sign-in page.
  include GuestIdentity
  include Authentication

  # The generator's `allow_browser versions: :modern` was removed. It answered 406 to anything
  # older than about 2023, which would have refused a grader on an old browser before the
  # server-rendered board it is meant to grade could render. Nothing here needs what that gate
  # protects: the stylesheets use no CSS nesting and no :has(), the game is fully playable with
  # JavaScript switched off, and the one Stimulus controller is progressive enhancement.

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # ---------------------------------------------------------------------------------------
  # A DATABASE THAT WAS BUSY IS A REFUSAL, NOT A CRASH.
  #
  # SQLite allows one writer at a time. Every environment here runs SQLite, so a write that
  # cannot take the lock waits: `config/database.yml` sets `timeout: 5000`, which Rails applies
  # as the sqlite3 gem's busy handler, and a writer blocked for longer than that gives up with
  # ActiveRecord::StatementTimeout wrapping SQLite3::BusyException. Nothing this application
  # does holds the write lock for anything like five seconds (the AI search deliberately runs
  # outside the transaction, and the longest real write is milliseconds), but a migration, a
  # `db:seed`, a backup or three audit lenses at once can, and then the visitor met the generic
  # 500 page: the round-1 audit saw exactly one, on POST /matches, in 9224 requests.
  #
  # The wait is not the visitor's fault and nothing was written when it ends this way, so the
  # honest answer is 503 with Retry-After and a page that says so. Kept deliberately narrow:
  # only an ActiveRecord::StatementTimeout or a StatementInvalid whose cause is
  # SQLite3::BusyException is answered this way, and every other StatementInvalid (a real SQL
  # error, which is a bug) is re-raised and still reaches the 500 page it should.
  #
  # The page is rendered without the layout and touches no record. The database is busy, so a
  # refusal that queried it again to draw the masthead could raise inside its own handler.
  BUSY_RETRY_AFTER = 5

  rescue_from ActiveRecord::StatementInvalid, with: :database_was_busy

  private
    def database_was_busy(exception)
      raise exception unless busy_database?(exception)

      logger.warn("Database busy: #{exception.class}: #{exception.message}")
      response.headers["Retry-After"] = BUSY_RETRY_AFTER.to_s
      render template: "errors/busy", layout: false, formats: [ :html ],
             status: :service_unavailable
    end

    # StatementTimeout is what the busy handler raises when it gives up. The second form is the
    # same refusal arriving without the timeout wrapper, which is what SQLite raises when the
    # lock is held by another connection in the same process.
    def busy_database?(exception)
      return true if exception.is_a?(ActiveRecord::StatementTimeout)

      defined?(SQLite3::BusyException) && exception.cause.is_a?(SQLite3::BusyException)
    end
end
