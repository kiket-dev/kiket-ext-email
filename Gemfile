# frozen_string_literal: true

source "https://rubygems.org"

gem "sinatra", "~> 4.1"
gem "puma", "~> 6.4"
gem "mail", "~> 2.8"  # SMTP email sending
gem "liquid", "~> 5.5"  # Template engine
gem "rack", "~> 3.1"
gem "json", "~> 2.7"

group :development, :test do
  gem "rspec", "~> 3.13"
  gem "rack-test", "~> 2.1"
  gem "webmock", "~> 3.23"
  gem "dotenv", "~> 3.1"
  gem "rubocop", "~> 1.65", require: false
  gem "mail-spy", "~> 1.0"  # Test helper for email
end
