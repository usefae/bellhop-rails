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

    module_function

    def server
      @server ||= ::ActionCable::Server::Base.new(config: configuration)
    end

    def configuration
      ::ActionCable::Server::Configuration.new.tap do |config|
        config.connection_class = -> { Bellhop::Cable::Connection }
        config.logger           = Bellhop.logger
        # `rails new --minimal` loads Action Cable with no config/cable.yml,
        # and publishing then raises on a nil config. Fall back to async.
        config.cable            = ::ActionCable.server.config.cable.presence || { "adapter" => "async" }
        config.worker_pool_size = ::ActionCable.server.config.worker_pool_size

        # The agent is a native application and sends no Origin header, which
        # Action Cable would otherwise refuse. There is no browser and no
        # cookie in play, so there is no forgery to protect against.
        config.disable_request_forgery_protection = true
      end
    end

    def channel_for(agent)
      channel_for_id(agent.id)
    end

    def channel_for_id(agent_id)
      "bellhop:agent:#{agent_id}"
    end

    def broadcast(agent, message)
      server.broadcast(channel_for(agent), message)
    end
  end
end
