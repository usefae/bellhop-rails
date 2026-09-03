# frozen_string_literal: true

require "test_helper"

# Renewal without a schedule: an agent connecting with an expiring credential
# is the cue, and the sweep runs off the connection thread. The cooldown keeps
# a reconnecting fleet from turning every handshake into a licensing call.
class OpportunisticRenewalTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  teardown { Bellhop.config.auto_renew = true }

  test "an agent connecting with an expiring credential triggers a sweep" do
    agent, machine = paired
    agent.update!(credential_expires_at: 5.days.from_now)
    machine.disconnect

    assert_enqueued_with(job: Bellhop::RenewCredentialsJob) do
      Bellhop::Testing::FakeAgent.new(agent.reload)
    end

    perform_enqueued_jobs
    assert_equal 1, @licensing.renewals
    assert agent.reload.credential_expires_at > Bellhop.config.renew_within.from_now
  end

  test "a fresh credential enqueues nothing and leaves the cooldown unspent" do
    agent, machine = paired
    machine.disconnect

    assert_no_enqueued_jobs only: Bellhop::RenewCredentialsJob do
      Bellhop::Testing::FakeAgent.new(agent.reload)
    end

    # The cooldown was not consumed by the fresh agent: an expiring one
    # arriving next still sweeps.
    agent.update!(credential_expires_at: 5.days.from_now)
    assert_enqueued_with(job: Bellhop::RenewCredentialsJob) do
      Bellhop::Testing::FakeAgent.new(agent.reload)
    end
  end

  test "a reconnecting fleet sweeps once per cooldown, not once per handshake" do
    agent, machine = paired
    agent.update!(credential_expires_at: 5.days.from_now)
    machine.disconnect

    assert_enqueued_jobs 1, only: Bellhop::RenewCredentialsJob do
      3.times { Bellhop::Testing::FakeAgent.new(agent.reload).disconnect }
    end
  end

  test "auto_renew false returns renewal to the host's own scheduler" do
    Bellhop.config.auto_renew = false
    agent, machine = paired
    agent.update!(credential_expires_at: 5.days.from_now)
    machine.disconnect

    assert_no_enqueued_jobs only: Bellhop::RenewCredentialsJob do
      Bellhop::Testing::FakeAgent.new(agent.reload)
    end

    Bellhop.renew!
    assert_equal 1, @licensing.renewals
  end
end
