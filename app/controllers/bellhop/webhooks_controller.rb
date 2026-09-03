# frozen_string_literal: true

module Bellhop
  # bellhop.dev's webhook. The event name is signed, so a verified delivery is
  # safe to dispatch on. `agent.deactivated` retires the removed agents.
  # Anything else, including events this version has never heard of, means
  # entitlements moved: re-mint every paired agent's credential. The work runs
  # from a job so this answers at once however large the fleet.
  class WebhooksController < ActionController::API
    def create
      unless WebhookVerifier.valid?(request.headers["Bellhop-Signature"],
        event: params[:event].to_s, app: params[:app].to_s)
        return render status: :unauthorized, json: { error: "invalid_signature" }
      end

      case params[:event]
      when "agent.deactivated"
        Bellhop.logger.info { "[bellhop] webhook received (#{params[:event]}); retiring removed agents" }
        Bellhop.retire_deactivated_later
      else
        Bellhop.logger.info { "[bellhop] webhook received (#{params[:event]}); refreshing credentials" }
        Bellhop.refresh_later
      end

      render status: :accepted, json: { ok: true }
    rescue LicensingError
      # The key set could not be fetched. A 5xx makes bellhop.dev redeliver.
      head :service_unavailable
    end
  end
end
