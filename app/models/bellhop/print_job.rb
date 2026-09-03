# frozen_string_literal: true

module Bellhop
  class PrintJob < ApplicationRecord
    self.table_name = "bellhop_print_jobs"

    FORMATS  = %w[zpl raw pdf gif].freeze
    STATUSES = %w[pending sent printed failed].freeze

    # The agent fails a larger job rather than truncating it.
    MAX_INLINE_BYTES = 50.megabytes

    belongs_to :agent, class_name: "Bellhop::Agent"

    serialize :options, coder: JSON, type: Hash

    validates :kind, presence: true
    validates :format, inclusion: { in: FORMATS }
    validates :status, inclusion: { in: STATUSES }

    scope :outstanding, -> { where(status: %w[pending sent]).order(:id) }
    scope :recent,      -> { order(id: :desc) }

    # Sent and never acknowledged: a jammed, empty, or unplugged printer.
    scope :unacknowledged, -> {
      where(status: "sent").where(sent_at: ..Bellhop.config.unacked_warning_after.ago)
    }

    # Create a job and push it if the agent is connected. If not, it stays
    # pending until the next handshake.
    #
    # A job with a `printer` goes to that printer, by the `id` from the
    # agent's last `hello`; one without routes by `format` to the operator's
    # default for labels or documents. `options` is checked here, at the call
    # site, for everything knowable without an agent.
    #
    # Exactly one of `data` and a `url` is delivered. Pass a block to build the
    # URL from the job, which a signed URL needs: it runs after the row exists
    # and before anything is delivered.
    def self.enqueue(agent:, kind:, format:, data: nil, url: nil, printer: nil, options: nil)
      format  = format.to_s
      printer = printer&.to_s

      # Same order the agent validates in: target, then format, then options.
      if printer && !agent.shares_printer?(printer)
        shared = agent.printers.map { |entry| entry["id"] }
        raise AgentError.new(
          "Agent #{agent.id} has not shared a printer \"#{printer}\". " +
            (shared.any? ? "It shares: #{shared.join(', ')}" : "Its last hello shared no printers."),
          agent: agent
        )
      end

      unless agent.supports?(format)
        raise AgentError.new(
          "Agent #{agent.id} does not advertise print:#{format}. It offers: #{agent.capabilities.join(', ')}",
          agent: agent
        )
      end

      options = PrintOptions.validate!(options, format: format, agent: agent) if options

      if data.nil? == (url.nil? && !block_given?)
        raise ArgumentError, "A print needs exactly one of `data` and `url`."
      end

      encoded = encode(data)
      if encoded && encoded.bytesize * 3 / 4 > MAX_INLINE_BYTES
        raise AgentError.new(
          "Inline documents are limited to 50 MB. Use a url instead.",
          agent: agent
        )
      end

      job = create!(agent: agent, kind: kind, format: format, data: encoded, url: url,
                    printer: printer, options: options, status: "pending")
      job.update!(url: yield(job)) if block_given?
      job.deliver
      job
    end

    # Push this job to whatever connection the agent has. Returns false when
    # it is offline.
    #
    # The status moves to `sent` before the message is handed over. An ack can
    # arrive while `Registry.deliver` is still on the stack (always for an
    # in-process agent), and writing `sent` afterwards would overwrite the
    # `printed` that already landed.
    def deliver
      previous = status
      update!(status: "sent", sent_at: Time.current)

      if Registry.deliver(agent, to_message)
        ActiveSupport::Notifications.instrument("print.bellhop", agent: agent, job: self)
        return true
      end

      # Nothing took it. Reload first: only this path can race with an ack.
      reload
      update!(status: previous, sent_at: nil) if status == "sent"
      false
    end

    def to_message
      message = { "type" => "print", "id" => id.to_s, "kind" => kind, "format" => format }
      # Absent rather than null: an absent `printer` routes by format, and an
      # absent option means the printer's default.
      message["printer"] = printer if printer.present?
      message["options"] = options if options.present?
      url.present? ? message.merge("url" => url) : message.merge("data" => data)
    end

    # Idempotent: re-acking a finished job rewrites the same columns.
    def record_ack(status:, error: nil)
      update!(status: status == "printed" ? "printed" : "failed", error: error, acked_at: Time.current)
    end

    def document
      data && Base64.decode64(data)
    end

    def self.encode(data)
      return nil if data.nil?

      Base64.strict_encode64(data.to_s)
    end
    private_class_method :encode
  end
end
