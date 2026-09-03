# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Bellhop
  module Generators
    # rails generate bellhop:install
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates the Bellhop initializer, migration, and route mount."

      def create_initializer
        template "initializer.rb", "config/initializers/bellhop.rb"
      end

      # Not `create_migration`: Rails::Generators::Migration owns that name.
      def create_bellhop_migration
        migration_template "migration.rb", "db/migrate/create_bellhop_tables.rb"
      end

      def mount_engine
        route %(mount Bellhop::Engine => "/bellhop")
      end

      def show_next_steps
        say <<~MESSAGE

          Bellhop is installed. Three things left:

            1. rails db:migrate

            2. Put your secret key somewhere real:
                 rails credentials:edit
                 bellhop:
                   secret_key: bh_sk_...

            3. Set public_url in config/initializers/bellhop.rb. Its host becomes
               the pairing host, which every credential is bound to and the agent
               compares byte for byte. Pick it once.

          Then check your work:

            rails bellhop:doctor

        MESSAGE
      end

      def self.next_migration_number(dirname)
        ActiveRecord::Generators::Base.next_migration_number(dirname)
      end
    end
  end
end
