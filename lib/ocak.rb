# frozen_string_literal: true

module Ocak
  VERSION = '0.2.0'

  def self.root
    File.expand_path('..', __dir__)
  end

  def self.templates_dir
    File.join(File.dirname(__FILE__), 'ocak', 'templates')
  end
end
