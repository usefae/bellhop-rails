# frozen_string_literal: true

module Bellhop
  class Engine < ::Rails::Engine
    isolate_namespace Bellhop

    initializer "bellhop.check_configuration", after: :load_config_initializers do
      config.after_initialize do
        # Raises on the any_cable adapter, here rather than from inside the
        # routes file where the socket is mounted.
        Bellhop::Cable.cable_config if Bellhop.cable_available?

        next unless Rails.env.production?
        next if Bellhop.config.public_url?

        Bellhop.logger.warn <<~MESSAGE
          [bellhop] public_url is not set. Pairing links cannot be generated and
          credentials cannot be minted until it is. Run `rails bellhop:doctor`.
        MESSAGE
      end
    end

    # No `rake_tasks` or `generators` block: Rails::Engine already loads
    # lib/tasks and lib/generators, and declaring them again runs every task twice.
  end
end
