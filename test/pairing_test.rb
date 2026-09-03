# frozen_string_literal: true

require "test_helper"

class PairingTest < ActiveSupport::TestCase
  test "returns a token, branding, and both transports" do
    agent = provision
    result  = Bellhop::ClaimExchange.perform(agent.claim_token, licensing: @licensing)

    assert result.agent_token.present?
    # Branding comes from the activation, so the name in `ready` matches this.
    assert_equal "Test App", result.agent.app_name
    assert_equal agent.id, result.agent.id
    assert result.agent.reload.paired?
  end

  test "is single use" do
    agent = provision
    token   = agent.claim_token

    Bellhop::ClaimExchange.perform(token, licensing: @licensing)
    assert_raises(Bellhop::ClaimExchange::ExpiredClaim) do
      Bellhop::ClaimExchange.perform(token, licensing: @licensing)
    end
  end

  test "expires" do
    agent = provision
    agent.update!(claim_expires_at: 1.second.ago)

    assert_raises(Bellhop::ClaimExchange::ExpiredClaim) do
      Bellhop::ClaimExchange.perform(agent.claim_token, licensing: @licensing)
    end
  end

  test "leaves the claim token valid when activation fails" do
    # Consuming first would strand a person at a desk with a dead link.
    agent = provision
    @licensing.fail_activation = "payment_required"

    assert_raises(Bellhop::LicensingError) do
      Bellhop::ClaimExchange.perform(agent.claim_token, licensing: @licensing)
    end
    assert agent.reload.claim_token_digest.present?, "the claim token was consumed by a failed activation"

    # The same link works once the problem is fixed.
    @licensing.fail_activation = nil
    assert Bellhop::ClaimExchange.perform(agent.claim_token, licensing: @licensing).agent_token
  end

  test "re-pairing rotates the token and cuts off the old machine" do
    agent = provision
    first   = Bellhop::ClaimExchange.perform(agent.claim_token, licensing: @licensing).agent_token
    machine   = Bellhop::Testing::FakeAgent.new(agent.reload)

    second = Bellhop::ClaimExchange.perform(agent.reload.repair!.claim_token, licensing: @licensing).agent_token

    refute_equal first, second
    assert_nil Bellhop::Agent.authenticate(first)
    assert_equal agent.id, Bellhop::Agent.authenticate(second).id
    assert_equal 4001, machine.closed&.first, "the old machine was not closed with 4001"
  end

  test "a pairing link is never logged" do
    logged = StringIO.new
    Bellhop.logger = Logger.new(logged)

    agent = provision
    Bellhop::ClaimExchange.perform(agent.claim_token, licensing: @licensing)

    refute_includes logged.string, agent.claim_token
  ensure
    Bellhop.logger = Rails.logger
  end

  test "the pairing link carries the public url and the claim token" do
    agent = provision
    assert_includes agent.pairing_link, CGI.escape(Bellhop.config.public_url)
    assert_includes agent.pairing_link, CGI.escape(agent.claim_token)
  end

  test "the pairing host drops a default port and keeps a real one" do
    with_public_url("https://deliver.example.com") { assert_equal "deliver.example.com", Bellhop.config.server_host }
    with_public_url("http://localhost:4000")       { assert_equal "localhost:4000", Bellhop.config.server_host }
    with_public_url("https://x.test:8443")         { assert_equal "x.test:8443", Bellhop.config.server_host }
  end

  test "decommissioning frees the plan slot" do
    agent = provision
    agent.decommission!(licensing: @licensing)

    assert_equal 1, @licensing.deactivations
    assert_nil Bellhop::Agent.find_by(id: agent.id)
  end

  test "renews credentials that expire soon" do
    agent, = paired
    assert_empty Bellhop.renew!(licensing: @licensing)[:renewed]

    agent.update!(credential_expires_at: 5.days.from_now)
    assert_equal [ agent.id ], Bellhop.renew!(licensing: @licensing)[:renewed]
    assert_equal 1, @licensing.renewals
  end

  private
    def with_public_url(url)
      previous = Bellhop.config.public_url
      Bellhop.config.public_url = url
      yield
    ensure
      Bellhop.config.public_url = previous
    end
end
