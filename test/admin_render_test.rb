# frozen_string_literal: true

require "test_helper"

# The admin is developer-facing and has no contract to keep, so this covers the
# one thing that would be silently broken by an edit: whether the three pages
# render at all, with their styling attached.
class AdminRenderTest < ActionDispatch::IntegrationTest
  setup do
    Bellhop.config.admin_authenticator = nil

    # The admin's forms are ordinary Rails forms and carry a token; an
    # integration test posting to them directly does not.
    @forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = false
  end

  teardown { ActionController::Base.allow_forgery_protection = @forgery_protection }

  test "the agents index renders with the embedded stylesheet" do
    agent, = paired(label: "Shipping Desk")
    agent.print(kind: "label", format: :zpl, data: Bellhop.test_label)

    get "/bellhop/agents"

    assert_response :success
    assert_select "style", /--plum: #2e1a33/
    assert_select "header.hdr .mark span", "Bellhop."
    assert_select ".braid"
    assert_select ".facts .fact", 3
    assert_select "table.register-wide .numeral", "001"
    assert_select ".seal.seal-good", "Online"

    # Printing is a button; the two standing actions are text below it.
    assert_select ".actions .btn-sm", "Label"
    assert_select ".actions .row-action-quiet", "Re-pair"
    assert_select ".actions .row-action:not(.row-action-quiet)", "Remove"
  end

  test "an unpaired agent is sealed as such" do
    provision(label: "Returns Counter")

    get "/bellhop/agents"

    assert_response :success
    assert_select ".seal.seal-wait", "Not paired"
    assert_select ".numeral.spent", "001"
  end

  test "the pairing page shows the link once, on a sheet" do
    agent = provision(label: "Back Room")

    post "/bellhop/agents/#{agent.id}/repair"

    assert_response :success
    assert_select ".sheet .field-mono[value^=?]", "bellhop://pair?"
    assert_select ".btn-gold", "Open in the agent on this computer"
  end

  test "a licensing failure renders the problem page" do
    def @licensing.create_agent(_label)
      raise Bellhop::LicensingError.new(code: "payment_required", status: 402)
    end

    post "/bellhop/agents", params: { label: "Shipping Desk" }

    assert_response :bad_gateway
    assert_select "h1.page-title", "Could not create that agent"
    assert_select ".paper .response", /payment_required/
  end
end
