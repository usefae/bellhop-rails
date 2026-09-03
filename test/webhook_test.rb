# frozen_string_literal: true

require "test_helper"

# FakeLicensing with a real Ed25519 keypair behind the well-known endpoint, so
# webhook signatures verify for real. The "junk" entry is deliberate: one
# malformed published key must not take down the one that verifies.
class SigningLicensing < FakeLicensing
  EVENT = "app.entitlements_changed"
  APP   = "bh_pk_test"

  attr_reader :signing_key, :kid
  attr_accessor :fail_keys

  def initialize(kid: "2026-08")
    super()
    @kid = kid
    @signing_key = OpenSSL::PKey.generate_key("ED25519")
    @fail_keys = false
  end

  def signing_keys
    raise Bellhop::LicensingError.new(code: "keys_unavailable", status: 0) if fail_keys

    { "keys" => [
      { "kid" => "junk", "alg" => "EdDSA", "public_key" => "AAAA" },
      { "kid" => kid, "alg" => "EdDSA", "public_key" => Base64.strict_encode64(signing_key.raw_public_key) }
    ] }
  end

  # The header bellhop.dev's AppWebhookJob would send.
  def sign(t: Time.now.to_i, event: EVENT, app: APP, kid: @kid)
    signature = Base64.strict_encode64(signing_key.sign(nil, "#{t}.#{event}.#{app}"))
    "t=#{t},kid=#{kid},v1=#{signature}"
  end
end

class WebhookVerifierTest < ActiveSupport::TestCase
  setup do
    Bellhop::WebhookVerifier.reset!
    @signing = SigningLicensing.new
  end

  teardown { Bellhop::WebhookVerifier.reset! }

  test "verifies a genuine signature" do
    assert valid?(@signing.sign)
  end

  test "refuses a signature over a different event or app" do
    header = @signing.sign(event: "app.entitlements_changed", app: "bh_pk_test")

    assert_not valid?(header, event: "app.deleted")
    assert_not valid?(header, app: "bh_pk_other")
  end

  test "refuses a delivery from outside the clock tolerance" do
    assert_not valid?(@signing.sign(t: Time.now.to_i - 6 * 60))
    assert valid?(@signing.sign(t: Time.now.to_i - 4 * 60))
  end

  test "refuses headers that do not parse" do
    assert_not valid?(nil)
    assert_not valid?("")
    assert_not valid?("t=soon,kid=2026-08,v1=abc")
    assert_not valid?("no commas or equals here")
    assert_not valid?("t=#{Time.now.to_i},kid=2026-08,v1=%%%not-base64%%%")
  end

  test "refuses an unknown kid, then picks up the rotated key set after the pause" do
    assert valid?(@signing.sign)

    rotated = SigningLicensing.new(kid: "2027-01")
    header = rotated.sign

    assert_not valid?(header, licensing: rotated), "inside the pause the unknown kid is refused without a fetch"
    assert valid?(header, licensing: rotated, now: Time.now + Bellhop::WebhookVerifier::REFETCH_INTERVAL + 1)
  end

  test "raises when the key set is needed and unreachable" do
    @signing.fail_keys = true

    assert_raises(Bellhop::LicensingError) { valid?(@signing.sign) }
  end

  private
    def valid?(header, event: SigningLicensing::EVENT, app: SigningLicensing::APP, licensing: @signing, now: Time.now)
      Bellhop::WebhookVerifier.valid?(header, event: event, app: app, licensing: licensing, now: now)
    end
end

class WebhookEndpointTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    Bellhop::WebhookVerifier.reset!
    @signing = SigningLicensing.new
    @licensing = @signing
    Bellhop.config.licensing = -> { @signing }
  end

  teardown { Bellhop::WebhookVerifier.reset! }

  test "a verified delivery is accepted quickly and refreshed from a job" do
    assert_enqueued_with(job: Bellhop::RefreshCredentialsJob) do
      post "/bellhop/webhook", params: payload, as: :json,
        headers: { "Bellhop-Signature" => @signing.sign }
    end

    assert_response :accepted
  end

  test "a delivery that does not verify changes nothing" do
    assert_no_enqueued_jobs do
      post "/bellhop/webhook", params: payload, as: :json,
        headers: { "Bellhop-Signature" => @signing.sign(app: "bh_pk_other") }
    end

    assert_response :unauthorized
  end

  test "answers 503 when the key set cannot be fetched, so bellhop.dev redelivers" do
    @signing.fail_keys = true

    post "/bellhop/webhook", params: payload, as: :json,
      headers: { "Bellhop-Signature" => @signing.sign }

    assert_response :service_unavailable
  end

  test "the whole path: a webhook lands and every paired agent is pushed a fresh credential" do
    agent, machine = paired

    perform_enqueued_jobs do
      post "/bellhop/webhook", params: payload, as: :json,
        headers: { "Bellhop-Signature" => @signing.sign }
    end

    assert_equal 1, @signing.renewals
    assert agent.reload.credential.present?
    assert(machine.transmitted.any? { |message| message["type"] == "credential" },
      "the fresh credential is pushed rather than waiting for the next ready")
  end

  test "an agent.deactivated delivery retires rather than refreshes" do
    assert_enqueued_with(job: Bellhop::RetireDeactivatedAgentsJob) do
      post "/bellhop/webhook", params: payload(event: "agent.deactivated"), as: :json,
        headers: { "Bellhop-Signature" => @signing.sign(event: "agent.deactivated") }
    end

    assert_no_enqueued_jobs only: Bellhop::RefreshCredentialsJob
    assert_response :accepted
  end

  test "an event this library has never heard of still refreshes" do
    assert_enqueued_with(job: Bellhop::RefreshCredentialsJob) do
      post "/bellhop/webhook", params: payload(event: "app.something_new"), as: :json,
        headers: { "Bellhop-Signature" => @signing.sign(event: "app.something_new") }
    end

    assert_response :accepted
  end

  test "the whole path: a removal on bellhop.dev lands and the agent is gone here too" do
    agent, machine = paired
    @signing.remote_agents.find { |remote| remote["id"] == agent.remote_id }["status"] = "deactivated"

    perform_enqueued_jobs do
      post "/bellhop/webhook", params: payload(event: "agent.deactivated"), as: :json,
        headers: { "Bellhop-Signature" => @signing.sign(event: "agent.deactivated") }
    end

    assert_not Bellhop::Agent.exists?(agent.id)
    assert_equal 4003, machine.closed&.first, "the live connection is refused, not left hanging"
    assert_equal 0, @signing.renewals, "retiring reads the agents list instead of renewing a fleet"
  end

  private
    def payload(event: SigningLicensing::EVENT)
      { event: event, app: SigningLicensing::APP }
    end
end

class RefreshTest < ActiveSupport::TestCase
  test "refresh! re-mints every paired agent, however far off expiry is" do
    agent, machine = paired

    assert_empty Bellhop.renew!(licensing: @licensing)[:renewed], "far from expiry, renew! has nothing to do"
    assert_equal [ agent.id ], Bellhop.refresh!(licensing: @licensing)[:renewed]
    assert_equal 1, @licensing.renewals
    assert(machine.transmitted.any? { |message| message["type"] == "credential" })
  end

  test "refresh! leaves unpaired agents alone" do
    provision

    assert_empty Bellhop.refresh!(licensing: @licensing)[:renewed]
    assert_equal 0, @licensing.renewals
  end
end

class RetireDeactivatedTest < ActiveSupport::TestCase
  test "retires exactly the agents bellhop.dev lists as deactivated" do
    gone, machine = paired(label: "Gone Desk")
    kept, = paired(label: "Kept Desk")
    @licensing.remote_agents.find { |remote| remote["id"] == gone.remote_id }["status"] = "deactivated"

    report = Bellhop.retire_deactivated!(licensing: @licensing)

    assert_equal [ gone.id ], report[:retired]
    assert_not Bellhop::Agent.exists?(gone.id)
    assert Bellhop::Agent.exists?(kept.id)
    assert_equal 4003, machine.closed&.first
  end

  # An unpaired local row whose remote was removed can never pair, so it goes
  # too.
  test "retires unpaired agents as well" do
    agent = provision
    @licensing.remote_agents.find { |remote| remote["id"] == agent.remote_id }["status"] = "deactivated"

    assert_equal [ agent.id ], Bellhop.retire_deactivated!(licensing: @licensing)[:retired]
    assert_not Bellhop::Agent.exists?(agent.id)
  end

  test "with nothing deactivated at the source, retires nothing" do
    agent, = paired

    assert_empty Bellhop.retire_deactivated!(licensing: @licensing)[:retired]
    assert Bellhop::Agent.exists?(agent.id)
  end
end
