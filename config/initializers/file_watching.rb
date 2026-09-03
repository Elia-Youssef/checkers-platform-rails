# How the development reloader learns that a file changed, and what that costs per request.
#
# config/environments/development.rb asks for ActiveSupport::EventedFileUpdateChecker so that
# no request has to walk the source tree; the measurements are in the comment there. That
# checker is backed by the listen gem, which on Linux watches with inotify.
#
# Two things about this project's development environment make the stock arrangement wrong,
# both measured (tests/build/session-5-overhead-pass.md):
#
#   1. Docker Desktop on Windows does not deliver inotify events for files edited on the host.
#      The container sees the new contents at once, but no event ever arrives, so the evented
#      checker never notices: an edit to a view was still not being served twenty seconds
#      later. listen must therefore poll.
#   2. listen's polling adapter polls once a second by default, and one pass over this source
#      tree costs 0.12 to 0.32 s on the bind mount. A background thread doing that every second
#      takes about a quarter of the wall time of a request that is busy running a Hard search
#      (the search went from 2.22 s to 2.83 s for the same 224,800 nodes). Polling every
#      POLL_SECONDS costs proportionally less, and a code change still appears within that.
#
# ActiveSupport calls Listen.to without options, so neither force_polling: true nor a latency
# can be passed through Rails. Listen::Adapter.select, which picks the backend, is the one
# seam there is. Everything below is development only and only when LISTEN_FORCE_POLLING is
# set, which compose.yaml does; on a host whose filesystem propagates inotify (Linux, macOS,
# or a checkout inside WSL2 rather than on a Windows drive) leave the variable unset and
# listen uses inotify, which is cheaper still.
#
# What this costs a developer: a change is picked up within POLL_SECONDS instead of on the
# next request. What it buys: the request path does no file system work at all.
if Rails.env.development? && ENV["LISTEN_FORCE_POLLING"] == "1" && defined?(::Listen::Adapter)
  module FileWatching
    # listen's own polling adapter with a longer interval. Listen::Adapter::Base reads
    # self.class.const_get("DEFAULTS"), so a subclass is enough to change it.
    class Polling < ::Listen::Adapter::Polling
      POLL_SECONDS = Float(ENV.fetch("LISTEN_POLL_SECONDS", 5))
      DEFAULTS = { latency: POLL_SECONDS, wait_for_delay: 0.05 }.freeze
    end
  end

  ::Listen::Adapter.singleton_class.prepend(Module.new do
    def select(_options = {})
      FileWatching::Polling
    end
  end)
end
