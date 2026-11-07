require "tmpdir"
require "logger"
require "rails"
require "active_model"
require "redis-client"
require "sidekiq"
require "roundtrips"

# 패널은 Rails.root, Rails.cache, Rails.backtrace_cleaner 를 쓴다. 그만큼만 갖춘 앱.
module RoundtripsSpec
  class Application < Rails::Application
    config.root = Dir.mktmpdir("roundtrips")
    config.eager_load = false
    config.logger = Logger.new(nil)
    config.cache_store = :memory_store
    config.secret_key_base = "roundtrips-spec"
  end
end
RoundtripsSpec::Application.initialize!

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.order = :random
end
