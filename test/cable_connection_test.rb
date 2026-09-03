# frozen_string_literal: true

require "test_helper"

# Action Cable as an engine, never as a protocol. These are the four places
# where its conventions have to get out of Bellhop's way, plus the one that
# would otherwise refuse every connection an agent ever makes.
class CableConnectionTest < ActionCable::Connection::TestCase
  tests Bellhop::Cable::Connection

  include BellhopTestCase

  setup do
    @agent = provision
    @token   = Bellhop::ClaimExchange.perform(@agent.claim_token, licensing: @licensing).agent_token
    @agent.reload
  end

  test "the agent sends no Origin header, and this server must not require one" do
    # Without this, `allow_request_origin?` returns false for a nil HTTP_ORIGIN
    # and every connection is refused with "Request origin not allowed".
    assert Bellhop::Cable.configuration.disable_request_forgery_protection,
      "the Bellhop cable server must not require an Origin header"
  end

  test "it mounts its own server rather than borrowing the host's" do
    # So that disabling forgery protection above cannot leak into the host
    # application's real Action Cable configuration.
    refute_same ActionCable.server, Bellhop::Cable.server
    refute ActionCable.server.config.disable_request_forgery_protection,
      "the host application's cable server was modified"
  end

  test "authenticates from the bearer token" do
    connect headers: { "Authorization" => "Bearer #{@token}" }
    assert_equal @agent.id, connection.agent_id
  end

  test "refuses an unknown token at the upgrade" do
    assert_reject_connection { connect headers: { "Authorization" => "Bearer nonsense" } }
  end

  test "refuses a connection with no token at all" do
    assert_reject_connection { connect }
  end

  test "refuses a protocol version it does not speak" do
    assert_reject_connection do
      connect headers: { "Authorization" => "Bearer #{@token}", "Bellhop-Protocol-Version" => "99" }
    end
  end

  test "dispatches Bellhop messages instead of Action Cable channel commands" do
    connect headers: { "Authorization" => "Bearer #{@token}" }

    # The harness gives a connection without a socket, so capture what would go
    # on the wire. Everything below this line is the real dispatch path.
    sent = []
    connection.define_singleton_method(:transmit) { |message| sent << message }

    connection.handle_channel_command(
      "type" => "hello", "protocol_version" => 1, "agent_version" => "1.0.0",
      "platform" => "macos", "session_id" => "abc", "capabilities" => [ "print:zpl" ]
    )

    assert_equal %w[print:zpl], @agent.reload.capabilities
    assert_equal "ready", sent.first["type"]
    assert_equal 1, sent.first["protocol_version"]
    # Always, which is what makes renewal invisible.
    assert sent.first["credential"].present?

    connection.handle_channel_command("type" => "ping", "token" => "abc")
    assert_equal({ "type" => "pong", "token" => "abc" }, sent.last)
  end

  test "sends no welcome, because there is no channel to confirm" do
    connect headers: { "Authorization" => "Bearer #{@token}" }
    assert_nil connection.send(:send_welcome_message)
  end

  test "does not put Action Cable's own heartbeat on the wire" do
    # Action Cable beats every three seconds with {"type":"ping","message":<ts>},
    # which collides by name with Bellhop's `ping` and would earn a `pong` 1,200
    # times an hour. Bellhop's keepalive is agent-driven.
    connect headers: { "Authorization" => "Bearer #{@token}" }
    assert_nil connection.beat
  end

  test "a refused connection never subscribes on behalf of an agent that is not there" do
    # Action Cable's `handle_open` rescues UnauthorizedError itself and returns
    # normally, so the code after `super` runs for refused connections too. The
    # first symptom of getting this wrong is a `WHERE id IS NULL` query, which
    # says nothing about authorization.
    connection = Bellhop::Cable::Connection.allocate
    def connection.agent_id = nil

    assert_nil connection.agent
    assert_nil connection.send(:subscribe_to_agent)
  end

  test "a supersede broadcast from elsewhere closes this socket with 4004" do
    connect headers: { "Authorization" => "Bearer #{@token}" }
    closed = capture_close(connection)

    connection.send(:handle_broadcast, { "type" => "__bellhop_supersede", "nonce" => "someone-else" })

    assert_equal 4004, closed.first
  end

  test "a supersede broadcast carrying this connection's own nonce is ignored" do
    connect headers: { "Authorization" => "Bearer #{@token}" }
    closed = capture_close(connection)

    connection.send(:handle_broadcast, { "type" => "__bellhop_supersede", "nonce" => connection.bellhop_nonce })

    assert_empty closed
  end

  test "beat closes a socket that has gone silent past the heartbeat window" do
    # A dead socket never says goodbye, so the beat timer is what notices.
    connect headers: { "Authorization" => "Bearer #{@token}" }
    closed = capture_close(connection)

    connection.instance_variable_set(:@bellhop_last_inbound_at, 10.minutes.ago)
    connection.beat

    assert_equal 1001, closed.first
  end

  test "beat leaves a lively socket alone" do
    connect headers: { "Authorization" => "Bearer #{@token}" }
    closed = capture_close(connection)

    connection.beat

    assert_empty closed
  end

  private
    # Intercept close_with: the TestCase's websocket double cannot carry a
    # real close frame, and what matters here is the decision, not the frame.
    def capture_close(connection)
      closed = []
      connection.define_singleton_method(:close_with) do |code, reason, retry_after: nil|
        closed << code << reason
      end
      closed
    end
end
