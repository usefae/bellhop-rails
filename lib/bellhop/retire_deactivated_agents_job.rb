# frozen_string_literal: true

module Bellhop
  # `Bellhop.retire_deactivated!` off the webhook request thread. Idempotent.
  class RetireDeactivatedAgentsJob < ActiveJob::Base
    def perform
      Bellhop.job_started(self.class)
      Bellhop.retire_deactivated!
    end
  end
end
