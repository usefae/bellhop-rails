# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
ENV["DATABASE_URL"] = "sqlite3::memory:"

require_relative "dummy/config/environment"
require "rails/test_help"
require "bellhop/testing"

# The real migration the install generator writes, so it is tested rather than
# paraphrased.
require_relative "../lib/generators/bellhop/install/templates/migration"
ActiveRecord::Migration.verbose = false
CreateBellhopTables.migrate(:up)

Bellhop.configure do |config|
  config.secret_key = "bh_sk_test"
  config.public_url = "http://localhost:3000"
  config.api_url    = "https://bellhop.test"
end

# A stand-in for bellhop.dev. Every test that pairs an agent needs one, because
# activation happens before a claim token is consumed and there is deliberately
# no way to skip it.
class FakeLicensing
  attr_reader :activations, :renewals, :deactivations, :remote_agents
  attr_accessor :fail_activation

  def initialize
    @next_id = 0
    @activations = @renewals = @deactivations = 0
    @fail_activation = nil
    @remote_agents = []
  end

  def create_agent(label)
    { "id" => (@next_id += 1), "label" => label, "status" => "pending" }
      .tap { |remote| @remote_agents << remote }
  end

  # The remote roll as GET /api/v1/agents answers it. Tests flip a status in
  # `remote_agents` to stand for a removal on bellhop.dev's dashboard.
  def agents
    { "agents" => remote_agents }
  end

  def activate(_remote_id)
    @activations += 1
    raise Bellhop::LicensingError.new(code: fail_activation, status: 402) if fail_activation

    activation
  end

  def renew(_remote_id)
    @renewals += 1
    activation
  end

  def deactivate(_remote_id)
    @deactivations += 1
    { "id" => 1, "status" => "deactivated" }
  end

  def app
    {
      "name" => "Test App", "plan" => "platform", "in_good_standing" => true,
      "active_agent_count" => 1,
      "entitlements" => { "agent_cap" => 100, "scales_allowed" => true, "max_printers" => nil }
    }
  end

  def signing_keys = { "keys" => [ { "kid" => "2026-08", "alg" => "EdDSA", "public_key" => "AAAA" } ] }

  private
    def activation
      {
        "credential" => "header.payload.signature",
        "expires_at" => 1.year.from_now.iso8601,
        "serial"     => "serial-1",
        "branding"   => { "app_name" => "Test App", "accent_color" => "#4F46E5" }
      }
    end
end

module BellhopTestCase
  extend ActiveSupport::Concern

  # Registered as a callback rather than written as `def setup`, so that it runs
  # before the `setup do ... end` blocks in individual test files.
  included do
    setup do
      @licensing = FakeLicensing.new
      fake = @licensing
      Bellhop.config.licensing = -> { fake }
      Bellhop::Registry.reset!
      Bellhop.last_renewal_sweep_at = nil
      Rails.cache.clear
    end

    teardown { Bellhop::Registry.reset! }
  end

  def provision(label: "Shipping Desk")
    Bellhop::Agent.provision(label: label, licensing: @licensing)
  end

  # A paired agent, and the in-process machine that holds its session.
  def paired(label: "Shipping Desk", **options)
    agent = provision(label: label)
    machine = Bellhop::Testing::FakeAgent.claim(agent, licensing: @licensing, **options)
    [ machine.agent, machine ]
  end
end

class ActiveSupport::TestCase
  include BellhopTestCase
  self.use_transactional_tests = true
end

class ActionDispatch::IntegrationTest
  include BellhopTestCase
end
