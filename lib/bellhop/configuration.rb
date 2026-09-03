# frozen_string_literal: true

module Bellhop
  class Configuration
    # Your app's secret key from bellhop.dev. Keep it in credentials.
    attr_accessor :secret_key

    # The licensing API. Defaults to https://bellhop.dev.
    attr_accessor :api_url

    # Display name and colour handed to the agent before it activates. After
    # that, the branding registered on bellhop.dev is used.
    attr_accessor :app_name, :accent_color

    # Requested agent keepalive, in seconds. The agent clamps it to 5..120.
    attr_accessor :heartbeat_seconds

    # How long a pairing link stays usable.
    attr_accessor :claim_ttl

    # Renew credentials this far ahead of expiry.
    attr_accessor :renew_within

    # Renew when an agent connects holding an expiring credential. Turn it off
    # if your own scheduled job calls Bellhop.renew!.
    attr_accessor :auto_renew

    # Attempts per IP per minute against the claim endpoint. nil disables it.
    attr_accessor :claim_rate_limit

    # A job sent and unacknowledged for this long is flagged in the admin.
    attr_accessor :unacked_warning_after

    # Called with the controller before the mounted admin renders. Return
    # falsey (or `head :forbidden` yourself) to refuse.
    #
    #   config.admin_authenticator = ->(controller) { controller.current_user&.admin? }
    attr_accessor :admin_authenticator

    # Builds the licensing client. Nothing else in the gem constructs one, so
    # this is where a retrying or instrumented client, or a test stub, goes.
    #
    #   config.licensing = -> { MyInstrumentedLicensing.new }
    attr_writer :licensing

    attr_writer :public_url, :poll_seconds

    def initialize
      @api_url               = "https://bellhop.dev"
      @heartbeat_seconds     = 20
      @claim_ttl             = 1.hour
      @renew_within          = 30.days
      @auto_renew            = true
      @claim_rate_limit      = 10
      @unacked_warning_after = 2.minutes
      @poll_seconds          = nil
    end

    # This application's public base URL. Its host is the pairing host: it goes
    # in every pairing link and every credential is bound to it, so changing it
    # after agents have paired means all of them re-pair.
    def public_url
      @public_url or raise ConfigurationError, <<~MESSAGE
        Bellhop needs a public_url. Its host becomes the pairing host, which
        every credential is bound to.

          Bellhop.configure do |config|
            config.public_url = "https://deliver.example.com"
          end
      MESSAGE
    end

    def public_url?
      @public_url.present?
    end

    # `host[:port]`, derived the way the agent derives it: a non-default port
    # is kept, a default one is dropped.
    def server_host
      uri = URI.parse(public_url)
      default = uri.scheme == "http" ? 80 : 443
      uri.port && uri.port != default ? "#{uri.host}:#{uri.port}" : uri.host
    end

    # How long the HTTP transport holds a poll open. Zero by default: a held
    # poll occupies a Puma thread for its whole duration, and Rails ships with
    # three per worker. At zero the agent polls every 3 seconds instead.
    # `rails bellhop:doctor` checks the arithmetic if you raise it.
    def poll_seconds
      @poll_seconds || 0
    end

    def licensing
      (@licensing || -> { Bellhop::Licensing.new }).call
    end

    def secret_key!
      secret_key.presence or raise ConfigurationError, <<~MESSAGE
        Bellhop needs a secret_key. It is on your app's page on bellhop.dev and
        is shown exactly once.

          Bellhop.configure do |config|
            config.secret_key = Rails.application.credentials.dig(:bellhop, :secret_key)
          end
      MESSAGE
    end

    def socket_url
      uri = URI.parse(public_url)
      scheme = uri.scheme == "https" ? "wss" : "ws"
      "#{scheme}://#{server_host}#{mount_path}/socket"
    end

    def http_url
      "#{public_url.chomp('/')}#{mount_path}"
    end

    # Where the engine is mounted, read from the host's routes.
    def mount_path
      @mount_path ||= begin
        route = Rails.application.routes.routes.find { |r| r.app.app == Bellhop::Engine }
        route ? route.path.spec.to_s.chomp("(.:format)").chomp("/") : "/bellhop"
      rescue StandardError
        "/bellhop"
      end
    end
  end

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end
  end
end
