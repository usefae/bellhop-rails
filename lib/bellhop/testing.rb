# frozen_string_literal: true

module Bellhop
  module Testing
    # An agent that exists only in your test process, for asserting in CI that
    # shipping an order enqueues one job, that a redelivered job is not printed
    # twice, and that your ack handling is idempotent.
    #
    #   agent = Bellhop::Testing::FakeAgent.claim(agent)
    #   agent.print(kind: "label", format: :zpl, data: zpl)
    #
    #   assert_equal 1, agent.printed.size
    #   assert_includes agent.printed.first[:data], "^XA"
    #
    # It deduplicates by job id, answers `ping`, re-sends the original ack for
    # a job it has already completed, and advertises a printer inventory, so
    # per-job targeting and options can be exercised. Each entry in `printed`
    # carries the `printer` and `options` the job named.
    class FakeAgent
      include Bellhop::Connectable

      # The default inventory: one label printer and one document printer.
      PRINTERS = [
        {
          "id" => "Fake_ZP450", "name" => "Fake ZP450",
          "capabilities" => {
            "papers" => [ "w288h432" ], "default_paper" => "w288h432",
            "dpi" => [ 203 ], "default_dpi" => 203,
            "duplex" => false, "color" => false
          }
        },
        {
          "id" => "Fake_Office_Laser", "name" => "Fake Office Laser",
          "capabilities" => {
            "papers" => [ "Letter", "A4" ], "default_paper" => "Letter",
            "bins" => [ "Auto", "Tray1" ], "default_bin" => "Auto",
            "dpi" => [ 600, 1200 ], "default_dpi" => 600,
            "duplex" => true, "color" => true
          }
        }
      ].freeze

      DEFAULT_PRINTERS = { "label" => "Fake_ZP450", "document" => "Fake_Office_Laser" }.freeze

      attr_reader :agent, :printed, :received, :transmitted

      # Redeem a pairing link as the agent would, then hold a session.
      def self.claim(agent, licensing: Bellhop.licensing, **options)
        result = Bellhop::ClaimExchange.perform(agent.claim_token, licensing: licensing)
        new(result.agent, token: result.agent_token, **options)
      end

      def initialize(agent, token: nil, capabilities: nil, printers: nil, default_printers: nil, fail_prints: false)
        @agent            = agent
        @token            = token
        @capabilities     = capabilities || %w[print:zpl print:raw print:pdf print:gif scale]
        @printers         = printers || PRINTERS
        @default_printers = default_printers || DEFAULT_PRINTERS
        @fail_prints      = fail_prints
        @printed          = []
        @received         = []
        @transmitted      = []
        @ledger           = {}

        Bellhop::Registry.register(@agent.id, self)
        hello
      end

      def transmit(message)
        message = message.deep_stringify_keys
        @transmitted << message

        case message["type"]
        when "print" then handle_print(message)
        when "ping"  then send_message("type" => "pong", "token" => message["token"])
        end
      end

      def close_with(code, reason, retry_after: nil)
        @closed = retry_after ? [ code, reason, retry_after ] : [ code, reason ]
        Bellhop::Registry.unregister(@agent.id, self)
      end

      def closed = @closed

      # A fresh `hello`, as the agent sends when the operator changes a setting.
      def hello(capabilities: nil, printers: nil, default_printers: nil)
        send_message(
          "type"             => "hello",
          "protocol_version" => Bellhop::PROTOCOL_VERSION,
          "agent_version"    => "1.0.0-fake",
          "platform"         => "macos",
          "session_id"       => SecureRandom.uuid,
          "capabilities"     => capabilities || @capabilities,
          "printers"         => printers || @printers,
          "default_printers" => default_printers || @default_printers
        )
      end

      def ping(token = "fake") = send_message("type" => "ping", "token" => token)
      def weigh(grams)         = send_message("type" => "weight", "grams" => grams, "stable" => true)
      def send_message(message) = Bellhop::Protocol.receive(agent.reload, self, message)

      # Deliver anything queued while the agent looked offline.
      def pump
        agent.reload.outstanding_jobs.each { |job| transmit(job.to_message) }
      end

      def disconnect
        Bellhop::Registry.unregister(agent.id, self)
      end

      private
        def handle_print(message)
          @received << message

          if (already = @ledger[message["id"]])
            return send_message(already)
          end

          ack = if @fail_prints
            { "type" => "ack", "id" => message["id"], "status" => "failed", "error" => "FakeAgent was told to fail" }
          else
            { "type" => "ack", "id" => message["id"], "status" => "printed", "error" => nil }
          end

          @ledger[message["id"]] = ack

          unless @fail_prints
            @printed << {
              id:      message["id"],
              kind:    message["kind"],
              format:  message["format"],
              printer: message["printer"],
              options: message["options"],
              data:    message["data"] && Base64.decode64(message["data"]),
              url:     message["url"]
            }
          end

          send_message(ack)
        end
    end
  end
end
