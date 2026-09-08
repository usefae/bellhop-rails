# frozen_string_literal: true

require "digest"

module Bellhop
  # bellhop.dev's webhook. The event name is signed, so a verified delivery is
  # safe to dispatch on. `agent.deactivated` retires the removed agents.
  # Anything else, including events this version has never heard of, means
  # entitlements moved: re-mint every paired agent's credential. The work runs
  # from a job so this answers at once however large the fleet.
  class WebhooksController < ActionController::API
    def create
      header = request.headers["Bellhop-Signature"]
      event  = params[:event].to_s
      app    = params[:app].to_s

      unless WebhookVerifier.valid?(header, event: event, app: app)
        return render status: :unauthorized, json: { error: "invalid_signature" }
      end

      # The signature proves bellhop.dev sent this and named that app. It does
      # not prove the app named is the one running here: every customer of
      # bellhop.dev holds genuine deliveries for its own app, and replaying one
      # at another installation would set that installation minting. So the
      # app named has to be ours.
      unless app == Bellhop.publishable_key
        return render status: :forbidden, json: { error: "wrong_app" }
      end

      # A 202 can be lost on the way back and the delivery retried, which is
      # harmless: the work is idempotent. Acting on it once and acknowledging
      # it every time after is what keeps a replayed header from being a way
      # to make this server mint on demand.
      unless first_delivery?(header)
        Bellhop.logger.info { "[bellhop] webhook received (#{event}) again; already acted on" }
        return render status: :accepted, json: { ok: true, duplicate: true }
      end

      case event
      when "agent.deactivated"
        Bellhop.logger.info { "[bellhop] webhook received (#{event}); retiring removed agents" }
        Bellhop.retire_deactivated_later
      else
        Bellhop.logger.info { "[bellhop] webhook received (#{event}); refreshing credentials" }
        Bellhop.refresh_later
      end

      render status: :accepted, json: { ok: true }
    rescue LicensingError
      # The key set, or the app record, could not be fetched. A 5xx makes
      # bellhop.dev redeliver.
      head :service_unavailable
    end

    private
      # The header is unique to a delivery: it carries the time it was signed
      # and the signature over it. It is remembered for as long as the
      # verifier would still accept it. A cache that keeps nothing (the null
      # store) answers true every time, and every delivery is acted on, as
      # before.
      def first_delivery?(header)
        key = "bellhop:webhook:#{Digest::SHA256.hexdigest(header.to_s)}"
        Rails.cache.write(key, true, unless_exist: true, expires_in: 2 * WebhookVerifier::TOLERANCE)
      end
  end
end
