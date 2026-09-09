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

  test "a key withdrawn from the published set stops verifying once the set ages out" do
    assert valid?(@signing.sign)

    withdrawn = SigningLicensing.new(kid: "2027-01")
    header = @signing.sign

    assert valid?(header, licensing: withdrawn), "inside the hour the fetched set is still trusted"
    assert_not valid?(header, licensing: withdrawn, now: Time.now + Bellhop::WebhookVerifier::MAX_AGE + 1)
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

  # Another customer's delivery is genuine: bellhop.dev signed it, and it
  # names that customer's app. It must not set this installation minting.
  test "a genuine delivery for a different app is refused" do
    assert_no_enqueued_jobs do
      post "/bellhop/webhook", params: payload(app: "bh_pk_other"), as: :json,
        headers: { "Bellhop-Signature" => @signing.sign(app: "bh_pk_other") }
    end

    assert_response :forbidden
  end

  test "the publishable key is read from the app record once and remembered" do
    2.times do |n|
      post "/bellhop/webhook", params: payload, as: :json,
        headers: { "Bellhop-Signature" => @signing.sign(t: Time.now.to_i - n) }
      assert_response :accepted
    end

    assert_equal 1, @signing.app_reads
  end

  test "a configured publishable key skips the lookup" do
    Bellhop.config.publishable_key = "bh_pk_test"
    @signing.fail_app = true

    post "/bellhop/webhook", params: payload, as: :json,
      headers: { "Bellhop-Signature" => @signing.sign }

    assert_response :accepted
    assert_equal 0, @signing.app_reads
  end

  test "answers 503 when the app record cannot be read, so bellhop.dev redelivers" do
    @signing.fail_app = true

    assert_no_enqueued_jobs do
      post "/bellhop/webhook", params: payload, as: :json,
        headers: { "Bellhop-Signature" => @signing.sign }
    end

    assert_response :service_unavailable
  end

  test "answers 503 when the app record names no publishable key" do
    @signing.define_singleton_method(:app) { { "name" => "Test App" } }

    post "/bellhop/webhook", params: payload, as: :json,
      headers: { "Bellhop-Signature" => @signing.sign }

    assert_response :service_unavailable
  end

  test "a burst of distinct deliveries waits on one refresh, and one more after it starts" do
    assert_enqueued_jobs 1, only: Bellhop::RefreshCredentialsJob do
      3.times do |n|
        post "/bellhop/webhook", params: payload, as: :json,
          headers: { "Bellhop-Signature" => @signing.sign(t: Time.now.to_i - n) }
        assert_response :accepted
      end
    end

    perform_enqueued_jobs

    assert_enqueued_jobs 1, only: Bellhop::RefreshCredentialsJob do
      post "/bellhop/webhook", params: payload, as: :json,
        headers: { "Bellhop-Signature" => @signing.sign(t: Time.now.to_i - 10) }
    end
  end

  # Two agents removed in the same second carry the same signature, so a
  # delivery seen before must still be acted on: every one enqueues, and
  # the coalescing is what keeps that to one waiting job.
  test "a delivery identical to the last one is still acted on" do
    header = @signing.sign

    post "/bellhop/webhook", params: payload(event: "agent.deactivated"), as: :json,
      headers: { "Bellhop-Signature" => @signing.sign(event: "agent.deactivated") }
    perform_enqueued_jobs

    assert_enqueued_jobs 1, only: Bellhop::RetireDeactivatedAgentsJob do
      post "/bellhop/webhook", params: payload(event: "agent.deactivated"), as: :json,
        headers: { "Bellhop-Signature" => @signing.sign(event: "agent.deactivated") }
    end
    assert_response :accepted
    assert_nil response.parsed_body["duplicate"]
  end

  # Rails' stores answer false from a write, rather than raising, when the
  # store is down. That must not read as "a job is already waiting".
  test "with the cache unavailable every delivery enqueues" do
    with_cache(UnavailableStore.new) do
      assert_enqueued_jobs 2, only: Bellhop::RefreshCredentialsJob do
        2.times do |n|
          post "/bellhop/webhook", params: payload, as: :json,
            headers: { "Bellhop-Signature" => @signing.sign(t: Time.now.to_i - n) }
          assert_response :accepted
        end
      end
    end
  end

  test "with a null store every delivery enqueues" do
    with_cache(ActiveSupport::Cache::NullStore.new) do
      assert_enqueued_jobs 2, only: Bellhop::RefreshCredentialsJob do
        2.times do |n|
          post "/bellhop/webhook", params: payload, as: :json,
            headers: { "Bellhop-Signature" => @signing.sign(t: Time.now.to_i - n) }
          assert_response :accepted
        end
      end
    end
  end

  test "a store that raises is treated as unavailable" do
    with_cache(RaisingStore.new) do
      assert_enqueued_jobs 1, only: Bellhop::RefreshCredentialsJob do
        post "/bellhop/webhook", params: payload, as: :json,
          headers: { "Bellhop-Signature" => @signing.sign }
      end
      assert_response :accepted
    end
  end

  # A queue adapter that will not take anything, standing in for a queue that
  # is full, down, or refusing.
  class RefusingAdapter
    def initialize(error)
      @error = error
    end

    def enqueue(_job) = raise(@error)
    def enqueue_at(_job, _at) = raise(@error)
    def enqueue_all(_jobs) = raise(@error)
  end

  def with_refusing_queue(job_class, error)
    original = job_class.queue_adapter
    job_class.enable_test_adapter(RefusingAdapter.new(error))
    yield
  ensure
    job_class.enable_test_adapter(original)
  end

  # Active Job answers a refused enqueue with false, not an exception: it
  # rescues its own EnqueueError and reports it that way. That false must not
  # become a 202 bellhop.dev takes as done, and must not leave a marker behind
  # that makes the redelivery find a job "already waiting".
  test "a queue that refuses the job answers 503 and the redelivery enqueues" do
    job = Bellhop::RetireDeactivatedAgentsJob
    with_refusing_queue(job, ActiveJob::EnqueueError.new("queue full")) do
      assert_no_enqueued_jobs only: job do
        post "/bellhop/webhook", params: payload(event: "agent.deactivated"), as: :json,
          headers: { "Bellhop-Signature" => @signing.sign(event: "agent.deactivated") }
      end
      assert_response :service_unavailable
    end

    assert_enqueued_jobs 1, only: job do
      post "/bellhop/webhook", params: payload(event: "agent.deactivated"), as: :json,
        headers: { "Bellhop-Signature" => @signing.sign(event: "agent.deactivated", t: Time.now.to_i - 1) }
    end
    assert_response :accepted
  end

  # An error Active Job does not rescue propagates as it is. The marker still
  # goes with it, so the redelivery enqueues.
  test "a queue that raises is not answered 202" do
    job = Bellhop::RefreshCredentialsJob
    with_refusing_queue(job, IOError.new("queue down")) do
      post "/bellhop/webhook", params: payload, as: :json,
        headers: { "Bellhop-Signature" => @signing.sign }
      assert_response :internal_server_error
    end

    assert_enqueued_jobs 1, only: job do
      post "/bellhop/webhook", params: payload, as: :json,
        headers: { "Bellhop-Signature" => @signing.sign(t: Time.now.to_i - 1) }
    end
    assert_response :accepted
  end

  test "a retire waits the same way, separately from a refresh" do
    assert_enqueued_jobs 1, only: Bellhop::RetireDeactivatedAgentsJob do
      2.times do |n|
        post "/bellhop/webhook", params: payload(event: "agent.deactivated"), as: :json,
          headers: { "Bellhop-Signature" => @signing.sign(event: "agent.deactivated", t: Time.now.to_i - n) }
      end
    end

    assert_enqueued_jobs 1, only: Bellhop::RefreshCredentialsJob do
      post "/bellhop/webhook", params: payload, as: :json,
        headers: { "Bellhop-Signature" => @signing.sign }
    end
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
    def payload(event: SigningLicensing::EVENT, app: SigningLicensing::APP)
      { event: event, app: app }
    end

    def with_cache(store)
      previous = Rails.cache
      Rails.cache = store
      yield
    ensure
      Rails.cache = previous
    end

    # What Rails' stores look like from outside when the store is down: every
    # write is refused and nothing can be read back.
    class UnavailableStore
      def write(*) = false
      def exist?(*) = false
      def read(*) = nil
      def delete(*) = false
    end

    class RaisingStore
      def write(*) = raise(IOError, "connection refused")
      def exist?(*) = raise(IOError, "connection refused")
      def read(*) = raise(IOError, "connection refused")
      def delete(*) = raise(IOError, "connection refused")
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
