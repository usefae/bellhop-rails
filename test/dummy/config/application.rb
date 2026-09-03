# frozen_string_literal: true

require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "active_job/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "action_cable/engine"

Bundler.require(*Rails.groups)
require "bellhop"

module Dummy
  class Application < Rails::Application
    config.load_defaults 7.2
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.logger = Logger.new(File::NULL)
    config.secret_key_base = "dummy" * 10
    config.action_cable.cable = { "adapter" => "async" }
    config.active_job.queue_adapter = :test
  end
end
