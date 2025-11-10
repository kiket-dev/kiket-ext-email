# syntax=docker/dockerfile:1
FROM ruby:3.4-slim

# Install dependencies
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential && \
    rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Install gems
COPY Gemfile* ./
RUN bundle install --without development test

# Copy application code
COPY . .

# Expose port
EXPOSE 9393

# Run the application
CMD ["bundle", "exec", "puma", "-C", "puma.rb"]
