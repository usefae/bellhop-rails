# frozen_string_literal: true

require "openssl"
require "base64"

module Bellhop
  # Verifies the Bellhop-Signature header on an inbound webhook.
  #
  # bellhop.dev signs `t.event.app` with the same Ed25519 keys that sign
  # credentials, so the public keys come from the well-known endpoint and
  # there is no webhook secret. The body is not signed: everything a receiver
  # acts on is in the signed string, and the only thing a delivery can cause
  # is a re-mint through the authenticated API.
  class WebhookVerifier
    # How far a delivery's `t` may sit from this machine's clock, in seconds.
    TOLERANCE = 5 * 60

    # Minimum seconds between key refetches when a kid is unknown.
    REFETCH_INTERVAL = 60

    LOCK = Mutex.new

    class << self
      # Raises LicensingError only when the key set is needed and cannot be
      # fetched. Answer that with a 5xx so the delivery is retried.
      def valid?(header, event:, app:, licensing: Bellhop.licensing, now: Time.now)
        fields = parse(header)
        return false unless fields
        return false if (now.to_i - fields[:t]).abs > TOLERANCE

        key = public_key(fields[:kid], licensing: licensing, now: now)
        return false unless key

        signed = "#{fields[:t]}.#{event}.#{app}"
        key.verify(nil, Base64.strict_decode64(fields[:v1]), signed)
      rescue ArgumentError
        false
      end

      # `t=1755245000,kid=2026-08,v1=<base64>` as a hash, or nil. Unknown
      # fields pass through, so a future signature version stays parseable.
      def parse(header)
        fields = header.to_s.split(",").to_h { |field| field.split("=", 2) }
        return nil unless fields["t"].to_s.match?(/\A\d+\z/)
        return nil if fields["kid"].blank? || fields["v1"].blank?

        { t: Integer(fields["t"]), kid: fields["kid"], v1: fields["v1"] }
      rescue ArgumentError
        nil
      end

      def reset!
        LOCK.synchronize do
          @keys = nil
          @fetched_at = nil
        end
      end

      private
        def public_key(kid, licensing:, now:)
          LOCK.synchronize do
            fetch(licensing) if @keys.nil?
            # An unknown kid usually means rotation, so ask again, rate limited.
            fetch(licensing) if !@keys.key?(kid) && now - @fetched_at >= REFETCH_INTERVAL
            @keys[kid]
          end
        end

        # A key that does not parse is skipped, so one malformed entry cannot
        # take down the ones that verify.
        def fetch(licensing)
          entries = Array(licensing.signing_keys["keys"])
          @keys = entries.each_with_object({}) do |entry, keys|
            raw = Base64.strict_decode64(entry["public_key"].to_s)
            keys[entry["kid"].to_s] = OpenSSL::PKey.new_raw_public_key("ED25519", raw)
          rescue ArgumentError, OpenSSL::PKey::PKeyError, OpenSSL::OpenSSLError
            Bellhop.logger.warn { "[bellhop] skipping signing key #{entry["kid"].inspect}: not a base64 Ed25519 public key" }
          end
          @fetched_at = Time.now
        end
    end
  end
end
