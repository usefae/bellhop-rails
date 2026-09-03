# frozen_string_literal: true

module Bellhop
  module Admin
    # Open in development, and refuses to render anywhere else until
    # `config.admin_authenticator` is set. `rails generate bellhop:admin`
    # copies these controllers and views into your application.
    class BaseController < ActionController::Base
      protect_from_forgery with: :exception

      layout "bellhop/admin"

      before_action :authenticate_admin

      private
        def authenticate_admin
          authenticator = Bellhop.config.admin_authenticator

          if authenticator
            head :forbidden unless authenticator.call(self)
          elsif !Rails.env.local?
            render plain: <<~MESSAGE, status: :forbidden
              The Bellhop admin is not configured.

              It lists your agents and can print to them or unpair them, so it
              refuses to render outside development until you say who may see it:

                Bellhop.configure do |config|
                  config.admin_authenticator = ->(controller) { controller.current_user&.admin? }
                end

              Or stop mounting the engine's admin and use your own.
            MESSAGE
          end
        end
    end
  end
end
