# frozen_string_literal: true

module Bellhop
  # The claim exchange without the HTTP around it, so pairing can also be
  # driven from a console, a job, or a test.
  module ClaimExchange
    Result = Struct.new(:agent, :agent_token, :activation, keyword_init: true)

    # Unknown, already used, and expired are deliberately indistinguishable.
    class ExpiredClaim < Bellhop::Error; end

    module_function

    def perform(claim_token, licensing: Bellhop.licensing)
      agent = Agent.for_claim(claim_token) or raise ExpiredClaim

      # Activate before consuming anything. A failure here leaves the claim
      # token valid, so the operator can retry the same link once the problem
      # is fixed.
      activation = licensing.activate(agent.remote_id)

      agent_token = Tokens.generate(32)
      branding    = activation["branding"] || {}

      agent.update!(
        token_digest:          Tokens.digest(agent_token),
        credential:            activation["credential"],
        credential_expires_at: activation["expires_at"],
        app_name:              branding["app_name"],
        accent_color:          branding["accent_color"],
        claim_token_digest:    nil,
        claim_expires_at:      nil
      )

      # Re-claiming rotates the token, so any machine holding the old one is cut off.
      Registry.close(agent, code: 4001, reason: "This agent was re-paired elsewhere.")

      Bellhop.logger.info { "[bellhop] agent #{agent.id} claimed; credential expires #{activation['expires_at']}" }

      Result.new(agent: agent, agent_token: agent_token, activation: activation)
    end
  end
end
