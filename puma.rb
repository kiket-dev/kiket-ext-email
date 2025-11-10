# frozen_string_literal: true

# Puma configuration for Email Extension

# Number of worker processes (0 = single mode, good for development)
workers ENV.fetch("WEB_CONCURRENCY", 0).to_i

# Threads per worker
threads_count = ENV.fetch("RAILS_MAX_THREADS", 5).to_i
threads threads_count, threads_count

# Port to bind
port ENV.fetch("PORT", 9393).to_i

# Environment
environment ENV.fetch("RACK_ENV", "development")

# Preload app for better performance in production
preload_app! if ENV["RACK_ENV"] == "production"

# Allow puma to be restarted by `bin/rails restart` command
plugin :tmp_restart
