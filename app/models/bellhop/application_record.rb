# frozen_string_literal: true

module Bellhop
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
  end
end
