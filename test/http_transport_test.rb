# frozen_string_literal: true

require "test_helper"

# The HTTP transport over the real mounted routes.
class HttpTransportTest < ActionDispatch::IntegrationTest
  setup do
    @agent = provision
    @token   = Bellhop::ClaimExchange.perform(@agent.claim_token, licensing: @licensing).agent_token
    @agent.reload
  end

  test "the whole loop: open a session, receive a print, send an ack" do
    post "/bellhop/sessions", params: hello, as: :json, headers: auth
    assert_response :created

    body = response.parsed_body
    session_id = body["session_id"]
    assert_equal "ready", body.dig("message", "type")
    assert_equal 1, body.dig("message", "protocol_version")
    # Always included, which is what makes renewal invisible.
    assert body.dig("message", "credential").present?
    # Zero by default: a held poll would occupy a Puma thread for its duration.
    assert_equal 0, body["poll_seconds"]

    job = @agent.reload.print(kind: "label", format: :zpl, data: "^XA^XZ")

    get "/bellhop/sessions/#{session_id}/messages", headers: auth
    assert_response :success
    messages = response.parsed_body["messages"]
    assert_equal 1, messages.size
    assert_equal({ "type" => "print", "id" => job.id.to_s, "kind" => "label", "format" => "zpl",
                   "data" => Base64.strict_encode64("^XA^XZ") }, messages.first)

    post "/bellhop/sessions/#{session_id}/messages",
      params: { messages: [ { type: "ack", id: job.id.to_s, status: "printed" } ] }, as: :json, headers: auth
    assert_response :success

    assert_equal "printed", job.reload.status
  end

  test "answers ping with pong on the same round trip" do
    post "/bellhop/sessions", params: hello, as: :json, headers: auth
    session_id = response.parsed_body["session_id"]

    post "/bellhop/sessions/#{session_id}/messages",
      params: { messages: [ { type: "ping", token: "abc" } ] }, as: :json, headers: auth

    assert_equal [ { "type" => "pong", "token" => "abc" } ], response.parsed_body["messages"]
  end

  test "the printer inventory rides hello through this transport too" do
    inventory = [ { "id" => "Desk_Zebra", "name" => "Desk Zebra",
                    "capabilities" => { "papers" => [ "w288h360" ], "dpi" => [ 203 ] } } ]

    post "/bellhop/sessions",
      params: hello.merge(printers: inventory, default_printers: { label: "Desk_Zebra" }),
      as: :json, headers: auth
    assert_response :created

    assert_equal inventory, @agent.reload.printers
    assert_equal({ "label" => "Desk_Zebra" }, @agent.default_printers)
  end

  test "an empty poll is normal" do
    post "/bellhop/sessions", params: hello, as: :json, headers: auth
    session_id = response.parsed_body["session_id"]

    get "/bellhop/sessions/#{session_id}/messages", headers: auth
    assert_response :success
    assert_equal [], response.parsed_body["messages"]
  end

  test "a new session displaces the old one with a 4004 advisory" do
    post "/bellhop/sessions", params: hello, as: :json, headers: auth
    first_id = response.parsed_body["session_id"]

    post "/bellhop/sessions", params: hello, as: :json, headers: auth
    assert_response :created

    get "/bellhop/sessions/#{first_id}/messages", headers: auth
    advisory = response.parsed_body["messages"].find { |m| m["type"] == "close" }
    assert_equal 4004, advisory["code"]
  end

  test "a close with a retry hint reaches the agent as an advisory" do
    post "/bellhop/sessions", params: hello, as: :json, headers: auth
    session_id = response.parsed_body["session_id"]

    # Establish the session as live, the state a fleet is in when a deploy lands.
    get "/bellhop/sessions/#{session_id}/messages", headers: auth

    Bellhop::Registry.close(@agent, code: 1001, reason: "Deploying.", retry_after: 45)

    get "/bellhop/sessions/#{session_id}/messages", headers: auth
    assert_response :success
    assert_equal [ { "type" => "close", "code" => 1001, "reason" => "Deploying.",
                     "retry_after_seconds" => 45 } ], response.parsed_body["messages"]
  end

  test "refuses an unknown token" do
    post "/bellhop/sessions", params: hello, as: :json,
      headers: { "Authorization" => "Bearer nonsense" }
    assert_response :unauthorized
  end

  test "refuses an unsupported protocol version" do
    post "/bellhop/sessions", params: hello.merge(protocol_version: 99), as: :json, headers: auth
    assert_response :upgrade_required
  end

  test "an unknown session is a 404, which means open a new one" do
    get "/bellhop/sessions/sess_nope/messages", headers: auth
    assert_response :not_found
  end

  test "outstanding jobs are redelivered when a new session opens" do
    job = @agent.print(kind: "label", format: :zpl, data: "^XA^XZ")
    assert_equal "pending", job.reload.status

    post "/bellhop/sessions", params: hello, as: :json, headers: auth
    session_id = response.parsed_body["session_id"]

    get "/bellhop/sessions/#{session_id}/messages", headers: auth
    assert_equal [ job.id.to_s ], response.parsed_body["messages"].map { |m| m["id"] }
  end

  test "the claim endpoint answers an expired link for a person, not a log" do
    post "/bellhop/claim", params: { claim_token: "nonsense" }, as: :json
    assert_response :not_found
    assert_equal "claim_expired", response.parsed_body.dig("error", "code")
    assert_match(/expired/i, response.parsed_body.dig("error", "message"))
  end

  test "the claim endpoint advertises both transports" do
    agent = provision
    post "/bellhop/claim", params: { claim_token: agent.claim_token }, as: :json
    assert_response :success

    assert_equal(
      [ { "type" => "websocket", "url" => "ws://localhost:3000/bellhop/socket" },
        { "type" => "http",      "url" => "http://localhost:3000/bellhop" } ],
      response.parsed_body["transports"]
    )
  end

  test "the claim endpoint is rate limited" do
    11.times { post "/bellhop/claim", params: { claim_token: "nonsense" }, as: :json }
    assert_response :too_many_requests
  end

  private
    def auth = { "Authorization" => "Bearer #{@token}" }

    def hello
      {
        type: "hello", protocol_version: 1, agent_version: "1.0.0", platform: "macos",
        session_id: SecureRandom.uuid, capabilities: %w[print:zpl print:pdf]
      }
    end
end
