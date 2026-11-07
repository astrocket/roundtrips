require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/isolated_execution_state"
require "rack"

require_relative "roundtrips/version"
require_relative "roundtrips/configuration"
require_relative "roundtrips/panel"

module Roundtrips
  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end
  end
end

require_relative "roundtrips/railtie" if defined?(Rails::Railtie)
