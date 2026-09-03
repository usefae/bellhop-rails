# frozen_string_literal: true

require "securerandom"
require "digest"

module Bellhop
  module Tokens
    module_function

    def generate(bytes = 32)
      SecureRandom.urlsafe_base64(bytes)
    end

    # Tokens are stored as digests, never in the clear.
    def digest(value)
      Digest::SHA256.hexdigest(value.to_s)
    end

    def secure_compare(left, right)
      return false if left.blank? || right.blank?

      ActiveSupport::SecurityUtils.secure_compare(left.to_s, right.to_s)
    end

    # `Authorization: Bearer <token>`, or nil.
    def bearer(header)
      header.to_s.start_with?("Bearer ") ? header.to_s.delete_prefix("Bearer ") : nil
    end
  end
end
