# frozen_string_literal: true

require_relative "lib/bellhop/version"

Gem::Specification.new do |spec|
  spec.name        = "bellhop-rails"
  spec.version     = Bellhop::VERSION
  spec.authors     = [ "Fae Software" ]
  spec.summary     = "Print to the label printers and read the USB scales at a physical location, from Rails."
  spec.description = <<~TEXT
    Bellhop gives a Rails application direct access to the printers and USB
    scales at a physical location, over a connection the application itself
    owns. No service sits in the middle of that traffic. This engine implements
    the agent protocol, both transports, pairing, and licensing.
  TEXT
  spec.homepage = "https://bellhop.dev"
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]          = spec.homepage
  spec.metadata["documentation_uri"]     = "https://bellhop.dev/docs"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "{app,config,lib}/**/*",
    "CHANGELOG.md",
    "MIT-LICENSE",
    "Rakefile",
    "README.md"
  ]

  spec.add_dependency "rails", ">= 7.2.0"
end
