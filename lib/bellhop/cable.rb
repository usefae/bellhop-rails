# frozen_string_literal: true

module Bellhop
  # Action Cable as an engine, never as a protocol. The agent speaks flat JSON
  # with no subscription handshake and no JSON inside JSON; what Action Cable
  # contributes is connection lifecycle and a pubsub backplane that lets any
  # Puma worker push to a socket held by another.
  #
  # This is its own `ActionCable::Server::Base`, so the host application's
  # cable configuration is untouched and request forgery protection can be
  # disabled here alone.
  module Cable
    # Deferred: the class subclasses ::ActionCable::Connection::Base, which may
    # not be loaded when `require "bellhop"` runs.
    autoload :Connection, "bellhop/cable/connection"

    ANYCABLE_MESSAGE = <<~MESSAGE
      Bellhop cannot use the any_cable adapter. It broadcasts to the AnyCable
      server and cannot subscribe from Rails, so a print created on one Puma
      worker would never reach a socket held by another. Give Bellhop its own
      backplane, in the shape of cable.yml:

        Bellhop.configure do |config|
          config.cable = { adapter: "solid_cable" }
        end

      Solid Cable keeps reading its own settings (connects_to, polling_interval)
      from cable.yml, so leave those there. For Redis, pass the url here:
      { adapter: "redis", url: ENV["REDIS_URL"] }. The agent's socket stays on
      Puma and never touches AnyCable.
    MESSAGE

    module_function

    def server
      @server ||= ::ActionCable::Server::Base.new(config: configuration)
    end

    def configuration
      ::ActionCable::Server::Configuration.new.tap do |config|
        config.connection_class = -> { Bellhop::Cable::Connection }
        config.logger           = Bellhop.logger
        config.cable            = cable_config
        config.worker_pool_size = ::ActionCable.server.config.worker_pool_size

        # The agent is a native application and sends no Origin header, which
        # Action Cable would otherwise refuse. There is no browser and no
        # cookie in play, so there is no forgery to protect against.
        config.disable_request_forgery_protection = true
      end
    end

    # The adapter config for Bellhop's server: `config.cable` when set,
    # otherwise the host application's. `rails new --minimal` loads Action
    # Cable with no cable.yml at all, hence the async fallback.
    def cable_config
      cable = Bellhop.config.cable.presence || ::ActionCable.server.config.cable.presence || { "adapter" => "async" }
      cable = cable.to_h.with_indifferent_access
      raise ConfigurationError, ANYCABLE_MESSAGE if cable["adapter"].to_s == "any_cable"

      cable
    end
  end
end
