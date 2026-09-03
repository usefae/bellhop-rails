# frozen_string_literal: true

require "test_helper"

class ProtocolTest < ActiveSupport::TestCase
  test "delivers a job and records the ack" do
    agent, machine = paired

    job = agent.print(kind: "label", format: :zpl, data: "^XA^FDhi^FS^XZ")

    assert_equal 1, machine.printed.size
    assert_equal "^XA^FDhi^FS^XZ", machine.printed.first[:data]
    assert_equal "printed", job.reload.status
    assert job.acked_at.present?
  end

  test "queues for an offline agent and delivers at the next handshake" do
    agent, machine = paired
    machine.disconnect
    agent.update!(last_seen_at: 1.hour.ago)

    job = agent.print(kind: "label", format: :zpl, data: "^XA^XZ")
    assert_equal "pending", job.reload.status

    reconnected = Bellhop::Testing::FakeAgent.new(agent.reload)

    assert_equal 1, reconnected.printed.size
    assert_equal "printed", job.reload.status
  end

  test "refuses a format the agent does not advertise" do
    agent, _agent = paired(capabilities: %w[print:zpl])

    error = assert_raises(Bellhop::AgentError) do
      agent.reload.print(kind: "slip", format: :pdf, data: "x")
    end
    assert_match(/does not advertise print:pdf/, error.message)

    assert agent.reload.print(kind: "label", format: :zpl, data: "x")
  end

  test "requires exactly one of data and url" do
    agent, _agent = paired

    assert_raises(ArgumentError) { agent.print(kind: "label", format: :zpl) }
    assert_raises(ArgumentError) { agent.print(kind: "label", format: :zpl, data: "x", url: "https://x") }
  end

  test "refuses inline documents over 50 MB" do
    agent, _agent = paired

    assert_raises(Bellhop::AgentError) do
      agent.print(kind: "doc", format: :pdf, data: "x" * 51.megabytes)
    end
  end

  test "a url is built from the job so a signature can name it" do
    agent, machine = paired

    job = agent.print(kind: "packing_slip", format: :pdf) { |j| "https://example.com/documents/#{j.id}?sig=abc" }

    assert_equal "https://example.com/documents/#{job.id}?sig=abc", machine.printed.first[:url]
    assert_nil machine.printed.first[:data]
  end

  test "does not re-send an outstanding job on a mid-session hello" do
    # The failure this guards: a burst of `hello` messages re-sending a job that
    # is still in flight, faster than the agent's ledger records it.
    agent, machine = paired
    agent.print(kind: "label", format: :zpl, data: "x")

    deliveries = machine.received.size
    50.times { machine.hello }

    assert_equal deliveries, machine.received.size
    assert_equal 1, machine.printed.size
  end

  test "answers ping with pong, echoing the token" do
    _agent, machine = paired
    machine.ping("abc123")

    pong = machine.transmitted.reverse.find { |m| m["type"] == "pong" }
    assert_equal "abc123", pong["token"]
  end

  test "ignores unknown message types and unknown fields" do
    _agent, machine = paired

    machine.send_message("type" => "telemetry", "cpu" => 12)
    machine.send_message("type" => "weight", "grams" => 500, "stable" => true, "humidity" => 30)

    # Still alive.
    machine.ping
    assert machine.transmitted.any? { |m| m["type"] == "pong" }
  end

  test "refuses an unsupported protocol version" do
    _agent, machine = paired
    machine.send_message("type" => "hello", "protocol_version" => 99)

    assert_equal 4002, machine.closed.first
  end

  test "a pacing hint rides the close, whatever the code" do
    agent, machine = paired

    Bellhop::Registry.close(agent, code: 1001, reason: "Deploying.", retry_after: 45)

    assert_equal [ 1001, "Deploying.", 45 ], machine.closed
  end

  test "presence writes are batched between flushes" do
    agent, machine = paired
    agent.update!(last_seen_at: 1.hour.ago)

    # Within the flush interval a message buffers instead of writing.
    machine.ping
    assert agent.reload.last_seen_at < 30.minutes.ago, "a buffered touch should not have written"

    # Once the interval has passed, the next message flushes the whole batch.
    Bellhop::Registry.instance_variable_set(:@touches_flushed_at, 10.minutes.ago)
    machine.ping
    assert agent.reload.last_seen_at > 1.minute.ago, "a due touch should have flushed"
  end

  test "a hello writes presence through immediately, never a flush interval late" do
    agent, machine = paired
    agent.update!(last_seen_at: 1.hour.ago)

    machine.hello
    assert agent.reload.last_seen_at > 1.minute.ago
  end

  test "a second connection for the same agent displaces the first with 4004" do
    agent, first = paired
    second = Bellhop::Testing::FakeAgent.new(agent)

    assert_equal [ 4004, "Replaced by a newer session." ], first.closed

    # And the registry now delivers to the newcomer, not the ghost.
    agent.print(kind: "label", format: :zpl, data: "x")
    assert_equal 1, second.printed.size
    assert_empty first.printed
  end

  test "acks are idempotent" do
    agent, machine = paired
    job = agent.print(kind: "label", format: :zpl, data: "x")

    2.times { machine.send_message("type" => "ack", "id" => job.id.to_s, "status" => "printed") }

    assert_equal "printed", job.reload.status
  end

  test "records a failure with its message" do
    agent, _agent = paired(fail_prints: true)
    job = agent.reload.print(kind: "label", format: :zpl, data: "x")

    assert_equal "failed", job.reload.status
    assert_match(/told to fail/, job.error)
  end

  test "ignores an ack for a job it does not have" do
    _agent, machine = paired
    assert_nothing_raised { machine.send_message("type" => "ack", "id" => "999999", "status" => "printed") }
  end

  test "weights arrive as notifications" do
    _agent, machine = paired
    seen = []
    ActiveSupport::Notifications.subscribed(->(*, payload) { seen << payload[:grams] }, "weight.bellhop") do
      machine.weigh(1240)
    end

    assert_equal [ 1240 ], seen
  end

  test "a later hello replaces the earlier one" do
    agent, machine = paired
    machine.hello(
      capabilities: %w[print:zpl],
      printers: [ { "id" => "Other_Printer", "name" => "Other Printer", "capabilities" => {} } ],
      default_printers: { "label" => "Other_Printer" }
    )

    assert_equal %w[print:zpl], agent.reload.capabilities
    assert_equal [ "Other_Printer" ], agent.printers.map { |printer| printer["id"] }
    assert_equal({ "label" => "Other_Printer" }, agent.default_printers)
  end
end
