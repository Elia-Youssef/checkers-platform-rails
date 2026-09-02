# Be sure to restart your server when you modify this file.

# The rules engine. lib/draughts is plain Ruby with no Rails and no gem dependency, so it
# is excluded from Zeitwerk in config/application.rb and required here, once, by name. Its
# own lib/draughts.rb requires the rest of the engine in dependency order.
#
# Consequences worth knowing:
#   * the engine is a library, not application code: it is not reloaded when a file under
#     lib/draughts changes in development, so restart the server after editing it;
#   * `Draughts` is available everywhere, including in eager-loaded production boots and in
#     `bin/rails runner`, before any application constant is autoloaded.
require "draughts"
