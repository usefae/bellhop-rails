# frozen_string_literal: true

Bellhop::Engine.routes.draw do
  # Pairing, once per agent. Unauthenticated by necessity: the agent has no
  # credential yet.
  post "claim", to: "claims#create"

  # bellhop.dev's webhook. Unauthenticated, but every delivery carries an
  # Ed25519 signature the controller verifies against the published keys.
  post "webhook", to: "webhooks#create"

  # The HTTP transport.
  post   "sessions",              to: "transport#create"
  get    "sessions/:id/messages", to: "transport#index"
  post   "sessions/:id/messages", to: "transport#update"
  delete "sessions/:id",          to: "transport#destroy"

  # The WebSocket transport. Skipped on an application without Action Cable.
  mount Bellhop::Cable.server => "/socket" if Bellhop.cable_available?

  # The admin. `rails g bellhop:admin` copies it into your app.
  resources :agents, only: %i[index create], controller: "admin/agents" do
    member do
      post :repair
      post :print
      delete :remove
    end
  end
  root to: "admin/agents#index"
end
