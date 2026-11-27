# frozen_string_literal: true

require_relative "lib/tuna/sdk/version"

Gem::Specification.new do |s|
  s.name = "tuna-sdk"
  s.version = Tuna::SDK::VERSION
  s.summary = "Open tuna.am tunnels from Ruby code"
  s.description = "Expose a local HTTP or TCP service at a public tuna.am address without installing the tuna CLI."
  s.authors = ["tuna.am authors"]
  s.email = "info@tuna.am"
  s.homepage = "https://github.com/yuccastream/tuna-sdk-ruby"
  s.license = "MIT"
  s.required_ruby_version = ">= 3.1"
  s.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb"] } + %w[README.md CHANGELOG.md LICENSE]
  s.metadata = {
    "source_code_uri" => "https://github.com/yuccastream/tuna-sdk-ruby",
    "changelog_uri" => "https://github.com/yuccastream/tuna-sdk-ruby/blob/main/CHANGELOG.md"
  }
  s.add_dependency "net-ssh", "~> 8.2"
end
