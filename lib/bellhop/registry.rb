# frozen_string_literal: true

module Bellhop
  # Gets a message to an agent, whichever transport it is on and whichever
  # process holds it: straight to a socket this process holds, onto the queue
  # of an HTTP session, or over Action Cable's pubsub to the worker that has
  # the socket.
  #
  # Presence is derived, never tracked. A crashed process cannot clean up a
  # flag, but every inbound message stamps `last_seen_at`, so an agent silent
  # for roughly three heartbeats is offline and the check heals itself.
  module Registry
    LOCK = Mutex.new
    TOUCH_LOCK = Mutex.new

    module_function

    # Connections held by this process.
    def local
      @local ||= {}
    end

    # A newer connection for an agent displaces the older one with 4004. The
    # map swap handles this process; the supersede broadcast reaches whichever
    # worker still holds yesterday's socket.
    def register(agent_id, connection)
      displaced = LOCK.synchronize do
        previous = local[agent_id.to_s]
        local[agent_id.to_s] = connection
        previous unless previous.nil? || previous.equal?(connection)
      end
      displaced&.close_with(4004, "Replaced by a newer session.")

      nonce = connection.respond_to?(:bellhop_nonce) ? connection.bellhop_nonce : nil
      announce_supersede(agent_id, nonce)

      # The agent is on a socket now. A lingering HTTP session would keep
      # collecting deliveries from other workers that nobody will poll for.
      Session.where(agent_id: agent_id).where(last_polled_at: Session.expiry_window.ago..).destroy_all
    end

    # Every subscribed connection for the agent except the one carrying
    # `nonce` closes itself with 4004.
    def announce_supersede(agent_id, nonce)
      return unless Bellhop.cable_available?

      Cable.server.broadcast(
        Cable.channel_for_id(agent_id),
        { "type" => "__bellhop_supersede", "nonce" => nonce }
      )
    end

    def unregister(agent_id, connection)
      LOCK.synchronize do
        local.delete(agent_id.to_s) if local[agent_id.to_s].equal?(connection)
      end
    end

    def local_connection(agent)
      LOCK.synchronize { local[agent.id.to_s] }
    end

    def online?(agent)
      return true if local_connection(agent)

      agent.last_seen_at.present? && agent.last_seen_at > offline_after.ago
    end

    def offline_after
      (Bellhop.config.heartbeat_seconds * 3).seconds
    end

    # Presence writes, batched. Everything that reads `last_seen_at` compares
    # it against a three-heartbeat window, so per-message writes are waste and
    # at fleet scale the dominant database load. Ids buffer here and flush as
    # one `update_all` per heartbeat interval per process. A `hello` still
    # writes through at once via `absorb_hello`.
    def touch(agent)
      due = TOUCH_LOCK.synchronize do
        touched[agent.id] = true
        if @touches_flushed_at.nil? || @touches_flushed_at <= flush_interval.ago
          @touches_flushed_at = Time.current
          true
        else
          false
        end
      end
      flush_touches! if due
    end

    def flush_touches!
      ids = TOUCH_LOCK.synchronize do
        drained = touched.keys
        @touched = {}
        drained
      end
      return if ids.empty?

      Agent.where(id: ids).update_all(last_seen_at: Time.current)
    end

    def flush_interval
      Bellhop.config.heartbeat_seconds.seconds
    end

    def touched
      @touched ||= {}
    end

    # Returns false when the agent is not reachable. The job stays pending and
    # goes out at the next handshake.
    def deliver(agent, message)
      if (connection = local_connection(agent))
        connection.transmit(message)
        return true
      end

      if (session = live_http_session(agent))
        session.push(message)
        return true
      end

      return false unless Bellhop.cable_available? && online?(agent)

      Cable.broadcast(agent, message)
      true
    end

    # Close whatever is live for an agent, now. Without this a re-paired or
    # removed machine keeps printing until it happens to reconnect.
    def close(agent, code:, reason:, retry_after: nil)
      if (connection = local_connection(agent))
        connection.close_with(code, reason, retry_after: retry_after)
        return
      end

      if (session = live_http_session(agent))
        message = { "type" => "close", "code" => code, "reason" => reason }
        message["retry_after_seconds"] = retry_after if retry_after
        session.push(message)
        return
      end

      return unless Bellhop.cable_available?

      message = { "type" => "__bellhop_close", "code" => code, "reason" => reason }
      message["retry_after_seconds"] = retry_after if retry_after
      Cable.broadcast(agent, message)
    end

    def live_http_session(agent)
      agent.sessions.where(last_polled_at: Session.expiry_window.ago..).order(:last_polled_at).last
    end

    def reset!
      LOCK.synchronize { @local = {} }
      TOUCH_LOCK.synchronize do
        @touched = {}
        @touches_flushed_at = nil
      end
    end
  end
end
