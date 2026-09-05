# frozen_string_literal: true

require "test_helper"

class BackplaneTest < ActiveSupport::TestCase
  # The routes file mounts the server. Build it before a test switches the
  # host to any_cable, or route loading in a later test would raise.
  setup { Bellhop::Cable.server }

  teardown do
    Bellhop.config.cable = nil
    ActionCable.server.config.cable = { "adapter" => "async" }
  end

  test "inherits the host application's cable adapter by default" do
    assert_equal "async", Bellhop::Cable.cable_config["adapter"]
  end

  test "config.cable overrides the host's, whatever the key style" do
    Bellhop.config.cable = { adapter: "async", polling_interval: "0.1.seconds" }

    assert_equal "async", Bellhop::Cable.cable_config["adapter"]
    assert_equal "0.1.seconds", Bellhop::Cable.cable_config[:polling_interval]
  end

  test "refuses to inherit any_cable, naming the fix" do
    ActionCable.server.config.cable = { "adapter" => "any_cable" }

    error = assert_raises(Bellhop::ConfigurationError) { Bellhop::Cable.cable_config }
    assert_match(/config\.cable = \{ adapter: "solid_cable"/, error.message)
  end

  test "refuses any_cable set directly as well" do
    Bellhop.config.cable = { adapter: "any_cable" }

    assert_raises(Bellhop::ConfigurationError) { Bellhop::Cable.cable_config }
  end

  test "config.cable makes a host on any_cable fine" do
    ActionCable.server.config.cable = { "adapter" => "any_cable" }
    Bellhop.config.cable = { adapter: "async" }

    assert_equal "async", Bellhop::Cable.cable_config["adapter"]
  end

  test "a broadcast reaches a subscriber through Bellhop's own server" do
    ready    = Queue.new
    received = Queue.new
    callback = ->(raw) { received << raw }
    Bellhop::Backplane.subscribe(42, callback, -> { ready << true })
    Timeout.timeout(2) { ready.pop }

    Bellhop::Backplane.broadcast(42, { "type" => "print", "id" => "1" })

    raw = Timeout.timeout(2) { received.pop }
    message = raw.is_a?(String) ? ActiveSupport::JSON.decode(raw) : raw
    assert_equal "print", message["type"]
  ensure
    Bellhop::Backplane.unsubscribe(42, callback) if callback
  end

  test "the doctor flags a host on any_cable with the remedy" do
    ActionCable.server.config.cable = { "adapter" => "any_cable" }

    check = Bellhop::Doctor.run(licensing: @licensing).find { |c| c.name == "cable adapter" }
    refute check.ok
    assert_match(/config\.cable/, check.remedy)
  end

  test "the doctor says when Bellhop is on its own backplane" do
    Bellhop.config.cable = { adapter: "async" }

    check = Bellhop::Doctor.run(licensing: @licensing).find { |c| c.name == "cable adapter" }
    assert_match(/from config\.cable/, check.detail)
  end
end
