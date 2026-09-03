# frozen_string_literal: true

Bellhop.configure do |config|
  # From your app's page on bellhop.dev. Shown exactly once.
  config.secret_key = Rails.application.credentials.dig(:bellhop, :secret_key)

  # This application's public base URL. Its host is the pairing host: it goes
  # in every pairing link and every credential is bound to it. Pick it once;
  # changing it after agents have paired means all of them re-pair.
  config.public_url =
    if Rails.env.production?
      "https://example.com" # <- yours
    else
      "http://localhost:3000"
    end

  # Who may see the mounted admin. Without this it refuses to render outside
  # development, because it lists your agents and can print to them or unpair
  # them.
  #
  #   config.admin_authenticator = ->(controller) { controller.current_user&.admin? }

  # How long the HTTP transport holds a poll open. Zero means it returns at
  # once and the agent polls every 3 seconds instead, so no Puma thread is
  # ever parked. Raise it only after counting your threads: a held poll
  # occupies one for its whole duration, and Rails ships with three.
  # `rails bellhop:doctor` does the arithmetic.
  #
  #   config.poll_seconds = 25

  # The licensing API. Defaults to https://bellhop.dev.
  #
  #   config.api_url = "https://bellhop.dev"
end
