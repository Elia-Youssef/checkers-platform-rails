# Bind every Turbo stream subscription to the connection that asks for it.
#
# MatchStreamAuthorization holds the rule and says why it lives on Turbo's own channel rather
# than on a subclass: the client names the channel a subscription runs through, so a guard
# anywhere else can be walked around by asking for Turbo::StreamsChannel by name.
#
# to_prepare rather than the initializer body, because Turbo::StreamsChannel is autoloaded
# (it comes from the turbo-rails engine's app/channels) and development unloads it on every
# reload. ActiveSupport::Concern makes a second include of the same module a no-op, so this
# adds the callback once however often the block runs.
Rails.application.config.to_prepare do
  Turbo::StreamsChannel.include MatchStreamAuthorization
end
