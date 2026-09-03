# frozen_string_literal: true

class CreateBellhopTables < ActiveRecord::Migration[7.2]
  def change
    create_table :bellhop_agents do |t|
      # The bellhop.dev agent id.
      t.bigint  :remote_id, null: false
      t.string  :label,     null: false

      # SHA-256 of the agent token, never the token itself.
      t.string   :token_digest
      # The signed credential, opaque. Encrypt it at rest if that is your habit.
      t.text     :credential
      t.datetime :credential_expires_at

      t.string   :claim_token_digest
      t.datetime :claim_expires_at

      # Branding as bellhop.dev has it, captured at activation.
      t.string :app_name
      t.string :accent_color

      # From the most recent `hello`. The serialized columns are nullable
      # because ActiveRecord writes NULL for an empty Array or Hash.
      t.string   :agent_version
      t.string   :platform
      t.text     :capabilities
      t.text     :printers
      t.text     :default_printers
      t.datetime :last_seen_at

      t.timestamps
    end

    add_index :bellhop_agents, :token_digest, unique: true
    add_index :bellhop_agents, :claim_token_digest, unique: true
    add_index :bellhop_agents, :remote_id

    create_table :bellhop_print_jobs do |t|
      t.references :agent, null: false, index: false,
        foreign_key: { to_table: :bellhop_agents }
      t.string :kind,   null: false
      t.string :format, null: false

      # Both nullable: a job that names nothing routes by format, and an
      # absent option means the printer's default.
      t.string :printer
      t.text   :options

      # Base64 document bytes, or somewhere the agent can fetch them. Exactly
      # one is delivered.
      t.text :data
      t.text :url

      t.string   :status, null: false, default: "pending"
      t.text     :error
      t.datetime :sent_at
      t.datetime :acked_at

      t.timestamps
    end

    add_index :bellhop_print_jobs, %i[agent_id status]

    # HTTP transport only.
    create_table :bellhop_sessions, id: :string do |t|
      t.references :agent, null: false,
        foreign_key: { to_table: :bellhop_agents }
      t.text     :queue
      t.datetime :last_polled_at, null: false

      t.timestamps
    end

    add_index :bellhop_sessions, :last_polled_at
  end
end
