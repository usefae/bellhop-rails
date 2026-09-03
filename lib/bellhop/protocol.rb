# frozen_string_literal: true

module Bellhop
  # The protocol, independent of transport. Both transports call `receive`
  # with anything that responds to `transmit` and `close_with`.
  module Protocol
    module_function

    def receive(agent, connection, message)
      return unless message.is_a?(Hash)

      # Any message is proof of life. Batched; see Registry.touch.
      Registry.touch(agent)

      case message["type"]
      when "hello"  then handle_hello(agent, connection, message)
      when "ack"    then handle_ack(agent, message)
      when "weight" then handle_weight(agent, message)
      when "event"  then handle_event(agent, message)
      when "ping"
        # Mandatory. Without a pong the agent drops and reconnects every 35 seconds.
        connection.transmit({ "type" => "pong", "token" => message["token"] }.compact)
      else
        # Unknown types are ignored, never closed over. That is the protocol's
        # only forward-compatibility mechanism.
        nil
      end
    end

    # `hello` opens a session, and also arrives mid-session whenever the
    # operator changes a printer or shares the scale.
    def handle_hello(agent, connection, message)
      if message["protocol_version"] != PROTOCOL_VERSION
        connection.close_with(4002, "This server speaks protocol version #{PROTOCOL_VERSION}.")
        return
      end

      handshake = !connection.bellhop_handshake_complete?
      connection.bellhop_handshake_complete!

      agent.absorb_hello(message)

      connection.transmit({
        "type"              => "ready",
        "protocol_version"  => PROTOCOL_VERSION,
        "app_name"          => agent.app_name.presence || Bellhop.config.app_name,
        "accent_color"      => agent.accent_color.presence || Bellhop.config.accent_color,
        # Always sent. The renewal job stores a fresh credential and the agent
        # adopts it from here on its next connection, with nobody at the machine.
        "credential"        => agent.credential,
        "heartbeat_seconds" => Bellhop.config.heartbeat_seconds
      }.compact)

      ActiveSupport::Notifications.instrument("hello.bellhop", agent: agent, message: message)

      # Only the first `hello` on a connection redelivers. A mid-session
      # `hello` changes nothing about which jobs are outstanding, and
      # re-sending a job still in flight can beat the agent's dedup ledger,
      # which is written when a job finishes. A reconnect is a new connection,
      # so at-least-once delivery still holds.
      return unless handshake

      flush_outstanding(agent)
      Bellhop.renew_if_due(agent)
    end

    def flush_outstanding(agent)
      outstanding = agent.outstanding_jobs.to_a
      return if outstanding.empty?

      Bellhop.logger.info { "[bellhop] redelivering #{outstanding.size} unacknowledged job(s) to agent #{agent.id}" }
      outstanding.each(&:deliver)
    end

    def handle_ack(agent, message)
      job = agent.print_jobs.find_by(id: message["id"])

      unless job
        Bellhop.logger.info { "[bellhop] ack for unknown job #{message['id']}, ignoring" }
        return
      end

      job.record_ack(status: message["status"], error: message["error"])
      ActiveSupport::Notifications.instrument("ack.bellhop", agent: agent, job: job)
    end

    # Already debounced by the agent: stable, non-zero, never re-sent unchanged.
    def handle_weight(agent, message)
      ActiveSupport::Notifications.instrument(
        "weight.bellhop",
        agent: agent, grams: message["grams"], stable: message["stable"] != false
      )
    end

    def handle_event(agent, message)
      ActiveSupport::Notifications.instrument(
        "event.bellhop",
        agent: agent, code: message["code"], message: message["message"]
      )
    end
  end
end
