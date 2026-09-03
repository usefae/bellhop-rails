# frozen_string_literal: true

Rails.application.routes.draw do
  mount Bellhop::Engine => "/bellhop"
end
