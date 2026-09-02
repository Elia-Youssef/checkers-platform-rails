require "test_helper"

# System tests drive headless Chromium inside the development image. Both the browser and its
# driver are Debian packages installed by Dockerfile.dev from one apt transaction, so their
# versions cannot drift, and pointing Selenium straight at them stops Selenium Manager from
# downloading a driver, so a test run never depends on the network.
#
# The two paths are the container's defaults and can be overridden with CHROMIUM_BINARY and
# CHROMEDRIVER_BINARY. When neither the override nor the default names an executable (a hosted
# CI runner, for example, which ships Google Chrome somewhere else), the setting is left out and
# Selenium finds the browser and driver itself.
#
#   --no-sandbox            the container runs as root, where Chromium's sandbox refuses to start
#   --disable-dev-shm-usage Chromium's shared memory use; compose.yaml also raises /dev/shm to
#                           1 GB, and this keeps the browser alive if a run ever happens without
#                           that setting
#   --window-size           a fixed window, so a layout assertion means the same thing everywhere
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  CHROMIUM_BINARY = ENV.fetch("CHROMIUM_BINARY", "/usr/bin/chromium")
  CHROMEDRIVER_BINARY = ENV.fetch("CHROMEDRIVER_BINARY", "/usr/bin/chromedriver")
  WINDOW_SIZE = [ 1400, 1000 ].freeze

  Selenium::WebDriver::Chrome::Service.driver_path = CHROMEDRIVER_BINARY if File.executable?(CHROMEDRIVER_BINARY)

  driven_by :selenium, using: :headless_chrome, screen_size: WINDOW_SIZE do |options|
    options.binary = CHROMIUM_BINARY if File.executable?(CHROMIUM_BINARY)
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--window-size=#{WINDOW_SIZE.join(",")}")
  end
end
