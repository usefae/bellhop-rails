# frozen_string_literal: true

module Bellhop
  # An HTTP-transport session and the queue of messages waiting for its next
  # poll. A socket-only deployment never touches this table.
  #
  # Expiry is this transport's dropped socket: the agent's poll loop is
  # continuous, so a gap this long means it is gone.
  class Session < ApplicationRecord
    self.table_name = "bellhop_sessions"

    belongs_to :agent, class_name: "Bellhop::Agent"

    serialize :queue, coder: JSON, type: Array

    # Twice the poll length, floored so the zero-poll default does not expire
    # every session at once.
    def self.expiry_window
      [ Bellhop.config.poll_seconds * 2, 30 ].max.seconds
    end

    scope :stale, -> { where(last_polled_at: ...expiry_window.ago) }

    def self.open!(agent)
      # A newer session displaces older ones with 4004. The advisory rides
      # each old session's queue; expiry cleans up if that poll never comes.
      where(agent: agent).where(last_polled_at: expiry_window.ago..).find_each do |old|
        old.push({ "type" => "close", "code" => 4004, "reason" => "Replaced by a newer session." })
      end

      created = create!(id: "sess_#{Tokens.generate(12)}", agent: agent, queue: [], last_polled_at: Time.current)
      # Any socket still held on any worker is stale too. The session id is
      # the nonce, which no socket carries.
      Registry.announce_supersede(agent.id, created.id)
      created
    end

    # The queue is the fanout on this transport: any process can write to a row.
    def push(message)
      with_lock do
        update!(queue: queue + [ message ])
      end
    end

    def drain
      with_lock do
        messages = queue
        update!(queue: [], last_polled_at: Time.current)
        messages
      end
    end

    def self.sweep_expired
      stale.find_each do |session|
        Bellhop.logger.info { "[bellhop] http session expired for agent #{session.agent_id}" }
        session.destroy
      end
    end
  end
end
