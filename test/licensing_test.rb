# frozen_string_literal: true

require "test_helper"

# The real client, with `perform` swapped out so what would go on the wire can
# be read back. Nothing here reaches a network.
class LicensingTest < ActiveSupport::TestCase
  class CapturingLicensing < Bellhop::Licensing
    attr_reader :requests

    private
      def perform(http_request, _uri)
        (@requests ||= []) << http_request

        Net::HTTPOK.new("1.1", "200", "OK").tap do |response|
          response.instance_variable_set(:@read, true)
          response.instance_variable_set(:@body, '{"id": 1}')
        end
      end
  end

  def client
    CapturingLicensing.new(
      secret_key: "bh_sk_test", api_url: "https://bellhop.test", server_host: "example.com"
    )
  end

  test "create_agent sends the Idempotency-Key header when given one" do
    licensing = client
    licensing.create_agent("Shipping Desk", idempotency_key: "agent-create-42")

    request = licensing.requests.last
    assert_equal "agent-create-42", request["Idempotency-Key"]
    assert_equal({ "label" => "Shipping Desk" }, JSON.parse(request.body))
  end

  test "create_agent sends no Idempotency-Key header when not given one" do
    licensing = client
    licensing.create_agent("Shipping Desk")

    assert_nil licensing.requests.last["Idempotency-Key"]
  end

  test "activate sends server_host as the request body" do
    licensing = client
    licensing.activate(42)

    request = licensing.requests.last
    assert_equal "/api/v1/agents/42/activate", request.path
    assert_equal({ "server_host" => "example.com" }, JSON.parse(request.body))
  end

  test "renew sends server_host as the request body" do
    licensing = client
    licensing.renew(42)

    request = licensing.requests.last
    assert_equal "/api/v1/agents/42/renew", request.path
    assert_equal({ "server_host" => "example.com" }, JSON.parse(request.body))
  end
end
