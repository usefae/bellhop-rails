# frozen_string_literal: true

module Bellhop
  # One physical location: a shipping desk, a counter, a back office. A row
  # here and an agent record on bellhop.dev, joined by `remote_id`.
  class Agent < ApplicationRecord
    self.table_name = "bellhop_agents"

    has_many :print_jobs, class_name: "Bellhop::PrintJob", dependent: :destroy
    has_many :sessions,   class_name: "Bellhop::Session",  dependent: :destroy

    validates :label, presence: true
    validates :remote_id, presence: true

    serialize :capabilities,     coder: JSON, type: Array
    serialize :printers,         coder: JSON, type: Array
    serialize :default_printers, coder: JSON, type: Hash

    scope :paired,   -> { where.not(token_digest: nil) }
    scope :unpaired, -> { where(token_digest: nil) }

    # Creates the agent on bellhop.dev first, so a full plan says so before a
    # local row exists, then the row and a single-use pairing link.
    #
    #   agent = Bellhop::Agent.provision(label: "Shipping Desk")
    #   agent.pairing_link
    def self.provision(label:, licensing: Bellhop.licensing)
      remote = licensing.create_agent(label)
      claim_token = Tokens.generate(24)

      create!(
        remote_id:          remote["id"],
        label:              label,
        claim_token_digest: Tokens.digest(claim_token),
        claim_expires_at:   Bellhop.config.claim_ttl.from_now
      ).tap { |agent| agent.instance_variable_set(:@claim_token, claim_token) }
    end

    # The agent a bearer token belongs to, or nil.
    def self.authenticate(token)
      return nil if token.blank?

      presented = Tokens.digest(token)
      agent = find_by(token_digest: presented)
      agent if agent && Tokens.secure_compare(agent.token_digest, presented)
    end

    # Unknown, already used, and expired all answer nil.
    def self.for_claim(token)
      return nil if token.blank?

      presented = Tokens.digest(token)
      agent = find_by(claim_token_digest: presented)
      return nil unless agent && Tokens.secure_compare(agent.claim_token_digest, presented)

      agent if agent.claim_expires_at&.future?
    end

    # Only set on the object that minted it. Never stored, never logged.
    attr_reader :claim_token

    # A fresh pairing link. Claiming it rotates the agent token, which is how
    # an agent moves to a new machine.
    def repair!
      claim_token = Tokens.generate(24)
      update!(
        claim_token_digest: Tokens.digest(claim_token),
        claim_expires_at:   Bellhop.config.claim_ttl.from_now
      )
      @claim_token = claim_token
      self
    end

    def pairing_link
      raise Bellhop::Error, "The claim token is only available on the object that minted it. Call #repair! for a fresh link." if claim_token.blank?

      server = CGI.escape(Bellhop.config.public_url)
      "bellhop://pair?server=#{server}&claim=#{CGI.escape(claim_token)}"
    end

    def paired?
      token_digest.present?
    end

    def online?
      Bellhop::Registry.online?(self)
    end

    # Queue a document and push it if the agent is connected.
    #
    #   agent.print(kind: "label", format: :zpl, data: zpl)
    #   agent.print(kind: "packing_slip", format: :pdf) { |job| signed_url(job) }
    #   agent.print(kind: "packing_slip", format: :pdf, url: url,
    #               printer: "Office_HP_LaserJet", options: { copies: 2, duplex: "long-edge" })
    #
    # See PrintJob.enqueue for what is checked before sending.
    def print(**attributes, &url_for)
      PrintJob.enqueue(agent: self, **attributes, &url_for)
    end

    # Unacknowledged jobs, oldest first. Redelivered at each handshake.
    def outstanding_jobs
      print_jobs.outstanding
    end

    # Refuses the agent's next connection with 4003, tells it now if it is
    # listening, and frees the slot on your plan. The bellhop.dev call is best
    # effort: a missed one costs a slot, not correctness.
    def decommission!(licensing: Bellhop.licensing)
      Registry.close(self, code: 4003, reason: "This agent was removed.")

      begin
        licensing.deactivate(remote_id)
      rescue LicensingError => e
        Bellhop.logger.warn { "[bellhop] deactivation failed for agent #{id} (#{e.code}); the plan slot stays used" }
      end

      destroy!
    end

    # A later `hello` replaces the earlier one wholesale.
    def absorb_hello(message)
      update!(
        agent_version:    message["agent_version"],
        platform:         message["platform"],
        capabilities:     Array(message["capabilities"]),
        printers:         message["printers"].is_a?(Array) ? message["printers"] : [],
        default_printers: message["default_printers"].is_a?(Hash) ? message["default_printers"] : {},
        last_seen_at:     Time.current
      )
    end

    # Empty capabilities mean the agent has never connected, and queueing for
    # an agent that has never paired is allowed.
    def supports?(format)
      capabilities.empty? || capabilities.include?("print:#{format}")
    end

    # The inventory from the most recent `hello`, looked up by the `id` a
    # print would name.
    #
    #   agent.printer("Zebra_Technologies_ZTC_GX420d")
    #   # => { "id" => ..., "name" => "Zebra GX420d",
    #   #      "capabilities" => { "papers" => [...], "default_paper" => ..., ... } }
    def printer(id)
      printers.find { |entry| entry["id"] == id.to_s }
    end

    # The same rule as `supports?`.
    def shares_printer?(id)
      capabilities.empty? || printer(id).present?
    end
  end
end
