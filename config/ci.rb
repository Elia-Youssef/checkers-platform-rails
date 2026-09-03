# Run using bin/ci

CI.run do
  step "Setup", "bin/setup --skip-server"

  step "Style: Ruby", "bin/rubocop"

  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Importmap vulnerability audit", "bin/importmap audit"
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"

  # The rules engine proves itself without Rails: this is the same command README.md
  # documents, and it fails if a Rails constant is defined, if perft 1 to 5 is not
  # 7, 49, 302, 1469, 7361, or if the suite takes longer than 2.0 seconds.
  step "Tests: Engine, Rails-free", "ruby", "-Ilib", "-Itest", "test/draughts_runner.rb"
  # Strength and timing of the computer opponent, too slow for the suite above (about 15 s).
  step "Tests: AI check", "ruby", "-Ilib", "-Itest", "test/draughts_ai_check.rb"

  step "Tests: Rails", "bin/rails test"
  step "Tests: System", "bin/rails test:system"
  # db/seeds.rb on a clean database, which is the only way to know that it still loads and that
  # it is still idempotent (SeedsTest loads it a second time from inside a transaction).
  #
  # db:test:prepare afterwards, because replanting leaves the seeded rows in the test database:
  # the next run's fixtures would delete the demo users out from under the demo match and the
  # fixture loader would refuse to start ("Foreign key violations found in your fixture data").
  # Purging here is what keeps two consecutive bin/ci runs identical.
  step "Tests: Seeds", "env RAILS_ENV=test bin/rails db:seed:replant db:test:prepare"

  # Optional: set a green GitHub commit status to unblock PR merge.
  # Requires the `gh` CLI and `gh extension install basecamp/gh-signoff`.
  # if success?
  #   step "Signoff: All systems go. Ready for merge and deploy.", "gh signoff"
  # else
  #   failure "Signoff: CI failed. Do not merge or deploy.", "Fix the issues and try again."
  # end
end
