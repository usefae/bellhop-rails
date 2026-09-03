# frozen_string_literal: true

module Bellhop
  # `Bellhop.renew!` off the connection thread. Idempotent.
  class RenewCredentialsJob < ActiveJob::Base
    def perform
      Bellhop.renew!
    end
  end
end
