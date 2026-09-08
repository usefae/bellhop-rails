# frozen_string_literal: true

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

      # There is deliberately no check for a delivery seen before. The signed
      # string is the time in whole seconds, the event, and the app, and the
      # signature over it is deterministic, so two deliveries in one second
      # (two agents removed together, say) are indistinguishable from one
      # delivery landing twice, and nothing outside the signed string can be
      # trusted to tell them apart. Every verified delivery is acted on. The
      # work is idempotent, and what bounds the cost of a replay is that the
      # job it asks for is enqueued once while one is already waiting.
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
  end
end
