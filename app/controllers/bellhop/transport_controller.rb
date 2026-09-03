# frozen_string_literal: true

module Bellhop
  # The HTTP transport: three routes and a table. This is what works behind
  # corporate proxies that break WebSocket upgrades, and it is the whole
  # transport on a host with no Action Cable.
  class TransportController < ActionController::API
    before_action :authenticate
    before_action :find_session, except: :create

    # POST /sessions. The body is `hello`.
    def create
      hello = params.to_unsafe_h.slice(*%w[type protocol_version agent_version platform session_id capabilities printers default_printers])
      return render(status: :bad_request, json: { error: "expected_hello" }) if hello["type"] != "hello"

      if hello["protocol_version"].to_i != PROTOCOL_VERSION
        return render(status: :upgrade_required, json: { error: "unsupported_version" })
      end

      session    = Session.open!(@agent)
      connection = HttpConnection.new(session, handshake: true)

      # Protocol.receive queues `ready` and then any outstanding jobs. `ready`
      # goes inline in this response; the rest waits for the first poll.
      Protocol.receive(@agent, connection, hello)
      queued = session.drain
      ready  = queued.shift
      queued.each { |message| session.push(message) }

      render status: :created, json: {
        session_id:   session.id,
        poll_seconds: Bellhop.config.poll_seconds,
        message:      ready
      }
    end

    # GET /sessions/:id/messages. An empty result is normal.
    def index
      render json: { messages: @session.drain }
    end

    # POST /sessions/:id/messages, batched. Anything queued meanwhile rides
    # back in the response.
    def update
      connection = HttpConnection.new(@session, handshake: false)
      Array(params[:messages]).each do |message|
        Protocol.receive(@agent, connection, message.to_unsafe_h)
      end

      render json: { messages: @session.drain }
    end

    # DELETE /sessions/:id. Expiry covers the case where it never arrives.
    def destroy
      @session.destroy
      render json: {}
    end

    private
      def authenticate
        @agent = Agent.authenticate(Tokens.bearer(request.headers["Authorization"]))
        render(status: :unauthorized, json: { error: "unauthorized" }) unless @agent
      end

      # A 404 means "open a new one".
      def find_session
        @session = @agent.sessions.find_by(id: params[:id])
        render(status: :not_found, json: { error: "no_such_session" }) unless @session
      end
  end
end
