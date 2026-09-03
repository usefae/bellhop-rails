# frozen_string_literal: true

module Bellhop
  # What the protocol needs from a transport: `transmit`, `close_with`, and
  # whether the first `hello` on this connection has happened. Only the first
  # `hello` redelivers outstanding jobs; see Protocol.handle_hello.
  module Connectable
    def bellhop_handshake_complete?
      @bellhop_handshake_complete == true
    end

    def bellhop_handshake_complete!
      @bellhop_handshake_complete = true
    end

    # Identifies this connection in a supersede broadcast: every connection
    # for the agent except the one carrying the announced nonce closes.
    def bellhop_nonce
      @bellhop_nonce ||= SecureRandom.hex(8)
    end
  end

  # The HTTP transport's connection: a session row and its queue. There is no
  # socket to write to, so `transmit` appends to the queue the next poll will
  # drain, and `close_with` queues the advisory `close` message.
  class HttpConnection
    include Connectable

    attr_reader :session

    def initialize(session, handshake:)
      @session = session
      @bellhop_handshake_complete = !handshake
    end

    def transmit(message)
      session.push(message.deep_stringify_keys)
    end

    def close_with(code, reason, retry_after: nil)
      advisory = { "type" => "close", "code" => code, "reason" => reason }
      advisory["retry_after_seconds"] = retry_after if retry_after
      transmit(advisory)
    end
  end
end
