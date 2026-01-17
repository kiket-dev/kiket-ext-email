# frozen_string_literal: true

source "https://rubygems.org"

ruby "~> 3.4"

# Kiket SDK for extension development
gem "kiket-sdk", github: "kiket-dev/kiket-ruby-sdk", branch: "main"

# Email sending
gem "mail", "~> 2.8"

# Template engine
gem "liquid", "~> 5.5"

# Development and testing
group :development, :test do
  gem "rspec", "~> 3.13"
  gem "rack-test", "~> 2.1"
  gem "webmock", "~> 3.23"
  gem "dotenv", "~> 3.1"
  gem "rubocop", "~> 1.69", require: false
  gem "rubocop-rspec", require: false
  gem "rubocop-rails-omakase", require: false
end
