# frozen_string_literal: true

require "rails/generators"

module Bellhop
  module Generators
    # rails generate bellhop:admin
    #
    # Copies the admin's controllers and views into your application. Rails
    # resolves the host application's paths ahead of an engine's, so from then
    # on these are the ones that render.
    class AdminGenerator < Rails::Generators::Base
      desc "Copies the Bellhop admin controllers and views into your application."

      def self.source_root
        @source_root ||= File.expand_path("../../../../app", __dir__)
      end

      def copy_controllers
        directory "controllers/bellhop/admin", "app/controllers/bellhop/admin"
      end

      def copy_views
        directory "views/bellhop/admin", "app/views/bellhop/admin"
        copy_file "views/layouts/bellhop/admin.html.erb", "app/views/layouts/bellhop/admin.html.erb"
      end

      def show_next_steps
        say <<~MESSAGE

          The Bellhop admin is now yours, in app/controllers/bellhop/admin and
          app/views/bellhop/admin. The engine's copies are no longer used.

          Two things you will probably want to change first:

            * The layout. It is standalone; point it at your own instead.
            * Authentication. BaseController#authenticate_admin still reads
              Bellhop.config.admin_authenticator. Replace it with whatever your
              application already uses.

        MESSAGE
      end
    end
  end
end
