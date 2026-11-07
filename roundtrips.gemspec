require_relative "lib/roundtrips/version"

Gem::Specification.new do |spec|
  spec.name = "roundtrips"
  spec.version = Roundtrips::VERSION
  spec.authors = ["astrocket"]
  spec.summary = "A development panel that shows every PostgreSQL, Redis and cache round trip, and N+1s, on your Rails pages"
  spec.description = "Collects the SQL, Redis commands and Rails cache calls made by each request, async request and Sidekiq job, with the line of app code that made them, and shows them in a panel at the bottom of the page."
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
