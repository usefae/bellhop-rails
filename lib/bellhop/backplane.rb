# frozen_string_literal: true

module Bellhop
  # The pubsub that reaches a socket held by another process: three calls,
  # keyed by agent id. The default rides Bellhop's own Action Cable server,
  # whose adapter is `config.cable` or, unset, the host application's.
  module Backplane
    module_function

    def channel(agent_id)
      "bellhop:agent:#{agent_id}"
    end

    def broadcast(agent_id, message)
      Cable.server.broadcast(channel(agent_id), message)
    end

    # `on_success` runs once the subscription is live, which on every adapter
    # is later than this call returns.
    def subscribe(agent_id, callback, on_success = nil)
      Cable.server.pubsub.subscribe(channel(agent_id), callback, on_success)
    end

    def unsubscribe(agent_id, callback)
      Cable.server.pubsub.unsubscribe(channel(agent_id), callback)
    end
  end
end
