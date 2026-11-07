module Roundtrips
  # development 에서만 붙는다. 다른 환경에서 Gemfile 에 들어 있어도 아무것도 하지 않는다.
  class Railtie < Rails::Railtie
    # config/initializers 에서 Roundtrips.configure 로 바꾼 값을 보고 붙인다.
    initializer "roundtrips.middleware", after: :load_config_initializers do |app|
      next unless Rails.env.development? && Roundtrips.config.enabled

      Roundtrips::Panel.subscribe!
      app.config.middleware.insert_before 0, Roundtrips::Panel
    end
  end
end
