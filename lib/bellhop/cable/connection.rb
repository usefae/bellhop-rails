# frozen_string_literal: true

module Bellhop
  module Cable
    # One agent socket. Four overrides keep Action Cable's own protocol off
    # the wire:
    #
    #   handle_channel_command  dispatch flat JSON instead of channel commands
    #   send_welcome_message    no `welcome`; there is no channel to confirm
    #   beat                    no 3-second `{"type":"ping"}` from Action Cable,
    #                           which would collide with Bellhop's own `ping`
    #   transmit                already raw, used as-is
    class Connection < ::ActionCable::Connection::Base
      include Bellhop::Connectable

      identified_by :agent_id

      def connect
        token = Bellhop::Tokens.bearer(request.headers["Authorization"])
        agent = Bellhop::Agent.authenticate(token)

        # Refused at the upgrade, which is what makes unpairing immediate.
        reject_unauthorized_connection unless agent

        declared = request.headers["Bellhop-Protocol-Version"].presence&.to_i
        reject_unauthorized_connection if declared && declared != Bellhop::PROTOCOL_VERSION

        self.agent_id = agent.id
        @bellhop_last_inbound_at = Time.current
        Bellhop::Registry.register(agent.id, self)
      end

      def disconnect
        Bellhop::Registry.unregister(agent_id, self)
      end

      def agent
        return nil if agent_id.blank?

        @agent ||= Bellhop::Agent.find_by(id: agent_id)
      end

      def handle_channel_command(payload)
        return unless agent

        @bellhop_last_inbound_at = Time.current
        Bellhop::Protocol.receive(agent, self, payload)
      end

      # Action Cable's heartbeat timer, reused as a dead-socket check and
      # nothing else. A machine that sleeps or drops off the network sends no
      # FIN, and without this the socket lingers for hours with deliveries
      # still being written into it.
      def beat
        last = @bellhop_last_inbound_at
        return if last.nil? || last > Bellhop::Registry.offline_after.ago

        logger.info "[bellhop] closing agent #{agent_id}'s socket: silent past the heartbeat window"
        close_with(1001, "No traffic within the heartbeat window.")
      end

      # The advisory message first, then the real close frame. A retry hint
      # always rides the advisory, because the close frame has no room for it.
      def close_with(code, reason, retry_after: nil)
        if code >= 4000 || retry_after
          advisory = { "type" => "close", "code" => code, "reason" => reason }
          advisory["retry_after_seconds"] = retry_after if retry_after
          transmit(advisory)
        end
        websocket.close(code, reason.to_s[0, 120])
      end

      private
        # Subscribe here rather than in `connect`, which runs before the socket
        # is established. `super` swallows UnauthorizedError, so a refused
        # connection reaches this line too and must not subscribe.
        def handle_open
          super
          subscribe_to_agent if agent_id.present?
        end

        def handle_close
          unsubscribe_from_agent
          super
        end

        def send_welcome_message; end

        def subscribe_to_agent
          return if agent.nil?

          callback = ->(raw) { handle_broadcast(raw) }
          @bellhop_subscription = callback
          server.event_loop.post { Bellhop::Backplane.subscribe(agent_id, callback) }
        end

        def unsubscribe_from_agent
          return unless @bellhop_subscription

          callback = @bellhop_subscription
          server.event_loop.post { Bellhop::Backplane.unsubscribe(agent_id, callback) }
        end

        # Everything outbound arrives here, from this process or another.
        def handle_broadcast(raw)
          message = raw.is_a?(String) ? ActiveSupport::JSON.decode(raw) : raw

          case message["type"]
          when "__bellhop_close"
            close_with(message["code"], message["reason"], retry_after: message["retry_after_seconds"])
          when "__bellhop_supersede"
            close_with(4004, "Replaced by a newer session.") unless message["nonce"] == bellhop_nonce
          else
            transmit(message)
          end
        rescue StandardError => e
          logger.error "[bellhop] could not deliver a broadcast: #{e.class}: #{e.message}"
        end
    end
  end
end
