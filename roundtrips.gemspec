require_relative "lib/roundtrips/version"

Gem::Specification.new do |spec|
  spec.name = "roundtrips"
  spec.version = Roundtrips::VERSION
  spec.authors = ["astrocket"]
  spec.summary = "Rails 개발 환경 페이지에 PostgreSQL·Redis·캐시 호출과 N+1 을 보여 주는 패널"
  spec.description = "요청, 비동기 요청, Sidekiq 잡마다 실행된 SQL, Redis 명령, Rails 캐시 호출을 코드 위치와 함께 모아 페이지 아래쪽 패널로 보여 준다."
  spec.homepage = "https://github.com/astrocket/roundtrips"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "railties", ">= 7.1"
  spec.add_dependency "activesupport", ">= 7.1"
end
