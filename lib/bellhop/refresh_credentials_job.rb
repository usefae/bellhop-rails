# frozen_string_literal: true

module Bellhop
  # `Bellhop.refresh!` off the webhook request thread. Idempotent.
  class RefreshCredentialsJob < ActiveJob::Base
    def perform
      Bellhop.job_started(self.class)
      Bellhop.refresh!
    end
  end
end
