# frozen_string_literal: true

module Bellhop
  # `Bellhop.retire_deactivated!` off the webhook request thread. Idempotent.
  class RetireDeactivatedAgentsJob < ActiveJob::Base
    def perform
      Bellhop.retire_deactivated!
    end
  end
end
