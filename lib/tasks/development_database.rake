# db:reset and db:drop say so when the development server is still holding the file they
# deleted. See lib/tasks/database_notice.rb for what happens without the notice and why this
# is a notice and not a refusal.
#
# Development only: the test environment's databases belong to bin/ci, which never runs beside
# a server, and production never resets anything.
require_relative "database_notice"

if Rails.env.development?
  %w[db:reset db:drop].each do |name|
    next unless Rake::Task.task_defined?(name)

    Rake::Task[name].enhance { DatabaseNotice.announce_at_exit(Rails.root) }
  end
end
