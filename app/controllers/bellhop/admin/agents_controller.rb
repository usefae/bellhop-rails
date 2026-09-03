# frozen_string_literal: true

module Bellhop
  module Admin
    class AgentsController < BaseController
      def index
        @agents = Agent.order(:id)
        @jobs   = PrintJob.recent.limit(20).includes(:agent)
      end

      def create
        @agent = Agent.provision(label: params.require(:label))
        render :pair
      rescue LicensingError => e
        @error = e
        render :problem, status: :bad_gateway
      end

      def repair
        @agent = Agent.find(params[:id]).repair!
        render :pair
      end

      def print
        Agent.find(params[:id]).print(kind: "label", format: :zpl, data: Bellhop.test_label)
        redirect_to agents_path
      rescue AgentError => e
        redirect_to agents_path, alert: e.message
      end

      def remove
        Agent.find(params[:id]).decommission!
        redirect_to agents_path
      end
    end
  end
end
