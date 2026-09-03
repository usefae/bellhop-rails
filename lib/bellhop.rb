# frozen_string_literal: true

require "bellhop/version"
require "bellhop/errors"
require "bellhop/configuration"
require "bellhop/tokens"
require "bellhop/licensing"
require "bellhop/webhook_verifier"
require "bellhop/print_options"
require "bellhop/connection"
require "bellhop/protocol"
require "bellhop/claim_exchange"
require "bellhop/registry"
require "bellhop/cable"
require "bellhop/doctor"
require "bellhop/engine" if defined?(Rails::Engine)
require "bellhop/refresh_credentials_job" if defined?(ActiveJob)
require "bellhop/renew_credentials_job" if defined?(ActiveJob)
require "bellhop/retire_deactivated_agents_job" if defined?(ActiveJob)

#   agent = Bellhop::Agent.provision(label: "Shipping Desk")
#   agent.pairing_link   # open this on the machine at that location
#
#   agent.print(kind: "label", format: :zpl, data: zpl)
#
#   ActiveSupport::Notifications.subscribe("weight.bellhop") do |event|
#     ShippingForm.fill(event.payload[:agent], grams: event.payload[:grams])
#   end
module Bellhop
  # A connecting agent with an expiring credential triggers a renewal sweep,
  # at most this often per process.
  OPPORTUNISTIC_RENEWAL_COOLDOWN = 6.hours

  RENEWAL_SWEEP_MUTEX = Mutex.new
  private_constant :RENEWAL_SWEEP_MUTEX

  class << self
    attr_writer :logger

    # Tests reset the renewal cooldown by assigning nil.
    attr_writer :last_renewal_sweep_at

    def logger
      @logger ||= defined?(Rails) && Rails.logger ? Rails.logger : Logger.new($stdout)
    end

    def licensing = config.licensing

    # False on an API-only or `--minimal` app, where action_cable/engine is not
    # loaded. The HTTP transport carries the same messages.
    def cable_available?
      defined?(::ActionCable::Server::Base) ? true : false
    end

    # Mint fresh credentials for agents expiring within `config.renew_within`.
    # A failed renewal is logged and the current credential stays in place.
    def renew!(licensing: Bellhop.licensing)
      remint(Agent.paired.where(credential_expires_at: ..config.renew_within.from_now), licensing: licensing)
    end

    # Mint fresh credentials for every paired agent. Entitlements are read at
    # mint time, so this is how a plan change reaches the fleet.
    def refresh!(licensing: Bellhop.licensing)
      remint(Agent.paired, licensing: licensing)
    end

    def refresh_later
      defined?(ActiveJob) ? RefreshCredentialsJob.perform_later : refresh!
    end

    def renew_later
      defined?(ActiveJob) ? RenewCredentialsJob.perform_later : renew!
    end

    # Called on every handshake. Throttled, so a reconnecting fleet triggers
    # one sweep rather than one per agent.
    def renew_if_due(agent)
      return unless config.auto_renew

      expires_at = agent.credential_expires_at
      return unless expires_at && expires_at <= config.renew_within.from_now
      return unless renewal_sweep_due?

      renew_later
    end

    # Remove every local agent that bellhop.dev lists as deactivated: close its
    # connection and destroy its row.
    def retire_deactivated!(licensing: Bellhop.licensing)
      deactivated = licensing.agents.fetch("agents", [])
        .select { |remote| remote["status"] == "deactivated" }
        .map { |remote| remote["id"] }

      retired = Agent.where(remote_id: deactivated).map do |agent|
        Registry.close(agent, code: 4003, reason: "This agent was removed.")
        agent.destroy!
        logger.info { "[bellhop] #{agent.label} was removed on bellhop.dev; retired here too" }
        agent.id
      end

      { retired: retired }
    end

    def retire_deactivated_later
      defined?(ActiveJob) ? RetireDeactivatedAgentsJob.perform_later : retire_deactivated!
    end

    private

    def renewal_sweep_due?
      RENEWAL_SWEEP_MUTEX.synchronize do
        next false if @last_renewal_sweep_at && @last_renewal_sweep_at > OPPORTUNISTIC_RENEWAL_COOLDOWN.ago

        @last_renewal_sweep_at = Time.current
        true
      end
    end

    def remint(agents, licensing:)
      renewed = []
      failed  = []

      agents.find_each do |agent|
        activation = licensing.renew(agent.remote_id)
        agent.update!(credential: activation["credential"], credential_expires_at: activation["expires_at"])
        # Best effort. The agent also adopts the new credential from its next `ready`.
        Registry.deliver(agent, { "type" => "credential", "credential" => activation["credential"] })
        renewed << agent.id
      rescue LicensingError => e
        failed << [ agent.id, e.code ]
        logger.warn { "[bellhop] renewal failed for agent #{agent.id} (#{e.code}); keeping the current credential" }
      end

      { renewed: renewed, failed: failed }
    end
  end

  # bellhop-logo.svg at 40x60 dots, one bit deep, as uncompressed `^GF` hex.
  # Core ZPL, so no printer needs a stored image or a font download to draw it.
  TEST_LABEL_LOGO = "^GFA,300,300,5,00000000000000000000000000000000000000000004000000000C000000001C000000007C00000001FC00000007FC00000003FC00000001FC00000001FC00000001FC00000001FC00000001FC00000001FC00000001FC00000001FC00000001FC00000001FC00000001FC00000001FC0FC00001FC7FF80001FDFFFE0001FFFFFF0001FF80FF8001FE003FC001FC001FE001F8000FF001F00007F001E00007F801C00003F801C00003F801800001FC01800001FC01000001FC01000001FC00008000FC0001C000FC00008000FC0001C000FC000FF000FC0019F800FC0033FC01FC0027FE01F8006FFE01F8004FFE01F0004FFE03F0007FFE03E000FFFF07C0000000078001FFFF8F0001FFFF9C00000000200000000000000000000000000000000000000000000000000000"

  # Width in dots of the mark plus the "Bellhop." wordmark, for centring.
  TEST_LABEL_LOCKUP = 218

  # The smallest label that proves the path works: the mark and two lines of
  # text in the font every ZPL printer has. Nothing that can wedge a printer's
  # firmware, and no `^PW`/`^LL` overriding its calibration.
  #
  # Without `width` it anchors top left and fits 1.25in stock at 203 dpi. ZPL
  # cannot ask a printer how wide its stock is, so pass `width` in dots (812
  # for 4in at 203 dpi) when you know it and the label is centred instead.
  def self.test_label(width: nil)
    if width
      dots = Integer(width)
      left = [ (dots - TEST_LABEL_LOCKUP) / 2, 0 ].max

      <<~ZPL.strip
        ^XA
        ^FO#{left},22#{TEST_LABEL_LOGO}^FS
        ^FO#{left + 52},40^A0N,50,50^FDBellhop.^FS
        ^FO0,100^A0N,30,30^FB#{dots},2,0,C,0^FDTest Label Print^FS
        ^XZ
      ZPL
    else
      <<~ZPL.strip
        ^XA
        ^FO20,22#{TEST_LABEL_LOGO}^FS
        ^FO72,40^A0N,50,50^FDBellhop.^FS
        ^FO20,100^A0N,30,30^FDTest Label Print^FS
        ^XZ
      ZPL
    end
  end
end
