# frozen_string_literal: true

module Bellhop
  # Everything that can be wrong with an environment before a single message
  # is exchanged. `rails bellhop:doctor` prints the result.
  module Doctor
    Check = Struct.new(:name, :ok, :detail, :remedy, keyword_init: true)

    module_function

    def run(licensing: nil)
      checks = []
      add = ->(name, ok, detail, remedy = nil) { checks << Check.new(name: name, ok: ok, detail: detail, remedy: remedy) }

      begin
        add.call "pairing host", true, Bellhop.config.server_host,
          "Every credential is bound to this host and the agent compares it byte for byte. Changing it means every agent re-pairs."
      rescue ConfigurationError => e
        add.call "pairing host", false, "not configured", e.message
      end

      licensing ||= begin
        Bellhop.licensing
      rescue ConfigurationError => e
        add.call "secret key", false, "not configured", e.message
        nil
      end

      if licensing
        begin
          app = licensing.app
          add.call "secret key", true, %(authenticated as "#{app['name']}")

          entitlements = app["entitlements"] || {}
          add.call "plan", app["in_good_standing"],
            "#{app['plan']}, #{app['active_agent_count']}/#{entitlements['agent_cap']} agents",
            app["in_good_standing"] ? nil : "Activation and renewal will fail with payment_required."

          add.call "scales", true,
            entitlements["scales_allowed"] ? "allowed on this plan" : "not on this plan",
            entitlements["scales_allowed"] ? nil : "Agents will not advertise `scale` or send weights no matter what the operator toggles. This is an entitlement, not a bug."

          add.call "printers", true,
            entitlements["max_printers"].nil? ? "unlimited" : "up to #{entitlements['max_printers']} shared per agent",
            entitlements["max_printers"] == 1 ? "One entry in each agent's inventory, both default roles pointing at it, every format landing on that queue." : nil

          add.call "webhook", true,
            app["webhook_registered"] ? "registered" : "not registered",
            app["webhook_registered"] ? nil : "Optional: without one, plan changes wait for the next renewal. Register #{webhook_url_hint} on your app's page on bellhop.dev and they land in moments."
        rescue LicensingError => e
          tls = e.message.match?(/certificate|self.signed|verify/i)
          add.call "secret key", false, "#{Bellhop.config.api_url} said #{e.code} (HTTP #{e.status})",
            tls ? "This host serves a certificate Ruby does not trust. If config.api_url points at a self-hosted licensing endpoint, add its CA to SSL_CERT_FILE." : "Check config.secret_key and config.api_url."
        end

        begin
          kids = Array(licensing.signing_keys["keys"]).map { |key| key["kid"] }
          add.call "signing keys", kids.any?, "#{Bellhop.config.api_url} publishes #{kids.join(', ').presence || 'nothing'}",
            "The agent verifies credentials offline against keys baked into its build. If its key set does not include these, every credential fails with \"signed with an unknown key\"."
        rescue LicensingError
          add.call "signing keys", false, "could not read #{Bellhop.config.api_url}/.well-known/bellhop-keys.json"
        end
      end

      if Bellhop.cable_available?
        begin
          adapter = Bellhop::Cable.cable_config["adapter"].to_s
          source  = Bellhop.config.cable.present? ? " from config.cable" : ""
          fleet   = paired_count

          case adapter
          when "async"
            add.call "cable adapter", false, "#{adapter}#{source}",
              "The async adapter is in-process only. With more than one Puma worker, a print created by one cannot reach a socket held by another. Use solid_cable or redis in production."
          when "solid_cable"
            if fleet < 1_000
              add.call "cable adapter", true, "#{adapter}#{source}, #{fleet} paired agent(s)",
                "Fine at this size. solid_cable polls the database per process with one channel per connected agent, so plan on the redis adapter by roughly a thousand agents."
            else
              add.call "cable adapter", false, "#{adapter}#{source}, #{fleet} paired agent(s)",
                "At this fleet size solid_cable's per-process database polling is real load in its own right. Switch Bellhop to the redis adapter."
            end
          else
            add.call "cable adapter", true, "#{adapter}#{source}"
          end
        rescue ConfigurationError => e
          add.call "cable adapter", false, "any_cable", e.message
        end
      end

      add.call "transports", true,
        Bellhop.cable_available? ? "websocket and http" : "http only",
        Bellhop.cable_available? ? nil : "This application has no Action Cable, so the socket route is not mounted. The HTTP transport carries the identical message set; print latency is 0-3s. Uncomment `require \"action_cable/engine\"` in config/application.rb to add the socket."

      checks.concat(thread_budget_checks)

      if tables_present?
        total  = Bellhop::Agent.count
        paired = Bellhop::Agent.paired.count
        online = Bellhop::Agent.paired.select(&:online?).size
        add.call "agents", true, "#{total} known, #{paired} paired, #{online} online"

        expiring = Bellhop::Agent.paired.where(credential_expires_at: ..Bellhop.config.renew_within.from_now).count
        add.call "credentials", expiring.zero?,
          expiring.zero? ? "none expiring soon" : "#{expiring} expiring within #{Bellhop.config.renew_within.inspect}",
          expiring.zero? ? nil : "Renewal is automatic as agents connect; run `rails bellhop:renew` to sweep now."
      else
        add.call "database", false, "the bellhop tables are missing",
          "Run `rails generate bellhop:install` and then `rails db:migrate`."
      end

      checks
    end

    def webhook_url_hint
      "#{Bellhop.config.public_url}#{Bellhop.config.mount_path}/webhook"
    rescue ConfigurationError
      "<your public URL>/bellhop/webhook"
    end

    # A held HTTP poll occupies a Puma thread for its whole duration, so a
    # handful of agents on a long poll can stop the application serving.
    def thread_budget_checks
      poll = Bellhop.config.poll_seconds
      if poll.zero?
        return [ Check.new(
          name: "poll budget", ok: true,
          detail: "poll_seconds is 0, so no request is ever held",
          remedy: "Print latency is 0-3s because the agent falls back to interval polling. That is the safe default for Rails."
        ) ]
      end

      threads = (ENV["RAILS_MAX_THREADS"] || 3).to_i
      agents  = paired_count
      safe    = agents < threads

      [ Check.new(
        name: "poll budget", ok: safe,
        detail: "poll_seconds is #{poll}; #{agents} paired agent(s) against #{threads} Puma thread(s) per worker",
        remedy: safe ? nil : "Each held poll occupies a thread for #{poll}s. With #{agents} agents on this transport every thread can be parked and the app stops serving. Set config.poll_seconds = 0, or raise RAILS_MAX_THREADS well above your agent count."
      ) ]
    end

    def tables_present?
      defined?(Bellhop::Agent) && Bellhop::Agent.table_exists?
    end

    def paired_count
      tables_present? ? Bellhop::Agent.paired.count : 0
    end
  end
end
