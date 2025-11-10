# frozen_string_literal: true

require "sinatra/base"
require "json"
require "mail"
require "liquid"
require "logger"

# Email Notification Extension
# Handles sending email notifications with template support
class EmailNotificationExtension < Sinatra::Base
  # Custom error classes
  class ValidationError < StandardError; end
  class TemplateError < StandardError; end
  class RateLimitError < StandardError; end

  configure do
    set :logging, true
    set :logger, Logger.new($stdout)

    # Configure Mail gem for SMTP
    Mail.defaults do
      delivery_method :smtp, {
        address: ENV.fetch("SMTP_HOST", "smtp.gmail.com"),
        port: ENV.fetch("SMTP_PORT", "587").to_i,
        domain: ENV.fetch("SMTP_DOMAIN", "kiket.dev"),
        user_name: ENV["SMTP_USERNAME"],
        password: ENV["SMTP_PASSWORD"],
        authentication: ENV.fetch("SMTP_AUTH", "plain").to_sym,
        enable_starttls_auto: ENV.fetch("SMTP_TLS", "true") == "true"
      }
    end

    # Email preferences storage (in-memory for now)
    set :email_preferences, {}

    # Digest queue for batching emails
    set :digest_queue, {}

    # Rate limiting state
    set :rate_limit_state, { count: 0, reset_at: Time.now + 60 }

    # Default templates
    set :default_templates, {
      issue_created: {
        subject: "New issue: {{ issue.title }}",
        body: <<~TEMPLATE
          A new issue has been created:

          **{{ issue.title }}**

          {{ issue.description }}

          Priority: {{ issue.priority }}
          Status: {{ issue.status }}

          View issue: {{ issue.url }}
        TEMPLATE
      },
      issue_assigned: {
        subject: "You've been assigned to: {{ issue.title }}",
        body: <<~TEMPLATE
          You have been assigned to work on:

          **{{ issue.title }}**

          {{ issue.description }}

          Due date: {{ issue.due_date }}

          View issue: {{ issue.url }}
        TEMPLATE
      },
      issue_transitioned: {
        subject: "Issue updated: {{ issue.title }}",
        body: <<~TEMPLATE
          Issue status changed from {{ transition.from }} to {{ transition.to }}:

          **{{ issue.title }}**

          {% if comment %}
          Comment: {{ comment }}
          {% endif %}

          View issue: {{ issue.url }}
        TEMPLATE
      },
      sla_breach: {
        subject: "🚨 SLA BREACH: {{ issue.title }}",
        body: <<~TEMPLATE
          **URGENT: SLA BREACH**

          Issue: {{ issue.title }}
          SLA: {{ sla.name }}
          Breach time: {{ breach.timestamp }}

          Immediate action required!

          View issue: {{ issue.url }}
        TEMPLATE
      }
    }
  end

  # Health check endpoint
  get "/health" do
    content_type :json
    {
      status: "healthy",
      service: "email-notifications",
      version: "1.0.0",
      timestamp: Time.now.utc.iso8601,
      smtp_configured: smtp_configured?
    }.to_json
  end

  # Send email notification
  post "/send" do
    content_type :json

    begin
      request_body = JSON.parse(request.body.read, symbolize_names: true)

      # Validate required fields
      validate_email_request!(request_body)

      # Check rate limiting
      check_rate_limit!

      # Check email preferences
      if suppression_enabled? && is_suppressed?(request_body[:to])
        logger.info "Email suppressed for #{request_body[:to]} per user preferences"
        status 200
        return {
          success: true,
          suppressed: true,
          to: request_body[:to],
          reason: "User has opted out of email notifications"
        }.to_json
      end

      # Render template if provided
      subject, body = render_email(request_body)

      # Send email
      send_email(
        to: request_body[:to],
        subject: subject,
        body: body,
        from: request_body[:from] || default_from_address,
        cc: request_body[:cc],
        bcc: request_body[:bcc],
        reply_to: request_body[:reply_to]
      )

      # Increment rate limit counter
      increment_rate_limit!

      status 200
      {
        success: true,
        to: request_body[:to],
        subject: subject,
        sent_at: Time.now.utc.iso8601
      }.to_json

    rescue JSON::ParserError => e
      logger.error "Invalid JSON: #{e.message}"
      status 400
      { success: false, error: "Invalid JSON in request body" }.to_json

    rescue ValidationError, TemplateError, RateLimitError => e
      logger.error "Error: #{e.message}"
      status 400
      { success: false, error: e.message }.to_json

    rescue StandardError => e
      logger.error "SMTP error: #{e.message}"
      logger.error e.backtrace.join("\n")
      status 502
      {
        success: false,
        error: "Email delivery error: #{e.message}"
      }.to_json
    end
  end

  # Queue email for digest delivery
  post "/digest/queue" do
    content_type :json

    begin
      request_body = JSON.parse(request.body.read, symbolize_names: true)
      validate_email_request!(request_body)

      recipient = request_body[:to]
      settings.digest_queue[recipient] ||= []
      settings.digest_queue[recipient] << {
        template: request_body[:template],
        context: request_body[:context],
        queued_at: Time.now.utc
      }

      status 200
      {
        success: true,
        to: recipient,
        queued_count: settings.digest_queue[recipient].length,
        queued_at: Time.now.utc.iso8601
      }.to_json

    rescue JSON::ParserError, ValidationError => e
      status 400
      { success: false, error: e.message }.to_json
    end
  end

  # Send digest emails
  post "/digest/send" do
    content_type :json

    begin
      sent_digests = []

      settings.digest_queue.each do |recipient, emails|
        next if emails.empty?

        # Render digest template
        subject = "Kiket Digest - #{emails.length} updates"
        body = render_digest(emails)

        send_email(
          to: recipient,
          subject: subject,
          body: body,
          from: default_from_address
        )

        sent_digests << {
          to: recipient,
          count: emails.length
        }
      end

      # Clear digest queue
      settings.digest_queue.clear

      status 200
      {
        success: true,
        digests_sent: sent_digests.length,
        sent_at: Time.now.utc.iso8601,
        digests: sent_digests
      }.to_json

    rescue StandardError => e
      logger.error "Digest send error: #{e.message}"
      status 500
      { success: false, error: e.message }.to_json
    end
  end

  # Update email preferences
  post "/preferences/update" do
    content_type :json

    begin
      request_body = JSON.parse(request.body.read, symbolize_names: true)

      raise ValidationError, "Email address is required" unless request_body[:email]

      email = request_body[:email].downcase.strip
      settings.email_preferences[email] = {
        suppressed: request_body[:suppressed] || false,
        digest_only: request_body[:digest_only] || false,
        frequency: request_body[:frequency] || "realtime",
        updated_at: Time.now.utc
      }

      status 200
      {
        success: true,
        email: email,
        preferences: settings.email_preferences[email],
        updated_at: Time.now.utc.iso8601
      }.to_json

    rescue JSON::ParserError, ValidationError => e
      status 400
      { success: false, error: e.message }.to_json
    end
  end

  # Check email preferences
  post "/preferences/check" do
    content_type :json

    begin
      request_body = JSON.parse(request.body.read, symbolize_names: true)
      raise ValidationError, "Email address is required" unless request_body[:email]

      email = request_body[:email].downcase.strip
      preferences = settings.email_preferences[email] || default_preferences

      status 200
      {
        success: true,
        email: email,
        preferences: preferences
      }.to_json

    rescue JSON::ParserError, ValidationError => e
      status 400
      { success: false, error: e.message }.to_json
    end
  end

  # Validate email template
  post "/template/validate" do
    content_type :json

    begin
      request_body = JSON.parse(request.body.read, symbolize_names: true)

      raise ValidationError, "Template body is required" unless request_body[:template]

      # Try to parse the template
      Liquid::Template.parse(request_body[:template])

      status 200
      {
        success: true,
        valid: true,
        message: "Template syntax is valid"
      }.to_json

    rescue Liquid::SyntaxError => e
      status 400
      {
        success: false,
        valid: false,
        error: "Invalid template syntax: #{e.message}"
      }.to_json

    rescue JSON::ParserError, ValidationError => e
      status 400
      { success: false, error: e.message }.to_json
    end
  end

  private

  def validate_email_request!(body)
    raise ValidationError, "Recipient (to) is required" unless body[:to]
    raise ValidationError, "Invalid email address" unless valid_email?(body[:to])

    if body[:template].nil? && body[:subject].nil?
      raise ValidationError, "Either template or subject is required"
    end

    if body[:template].nil? && body[:body].nil?
      raise ValidationError, "Either template or body is required"
    end
  end

  def valid_email?(email)
    email.to_s.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
  end

  def render_email(request_body)
    if request_body[:template]
      # Use predefined template
      template_name = request_body[:template].to_sym
      template = settings.default_templates[template_name]

      raise TemplateError, "Template '#{template_name}' not found" unless template

      context = request_body[:context] || {}

      subject_template = Liquid::Template.parse(template[:subject])
      body_template = Liquid::Template.parse(template[:body])

      subject = subject_template.render(context.transform_keys(&:to_s))
      body = body_template.render(context.transform_keys(&:to_s))

      [subject, body]
    else
      # Use raw subject and body
      [request_body[:subject], request_body[:body]]
    end
  end

  def render_digest(emails)
    digest_template = <<~TEMPLATE
      You have {{ count }} updates:

      {% for email in emails %}
      ---
      {{ email.rendered_body }}

      {% endfor %}

      ---
      To change your email preferences, visit your settings.
    TEMPLATE

    template = Liquid::Template.parse(digest_template)
    template.render({
      "count" => emails.length,
      "emails" => emails.map { |e|
        _, body = render_email(template: e[:template], context: e[:context])
        { "rendered_body" => body }
      }
    })
  end

  def send_email(to:, subject:, body:, from:, cc: nil, bcc: nil, reply_to: nil)
    mail = Mail.new do
      to to
      from from
      subject subject
      body body
      cc cc if cc
      bcc bcc if bcc
      reply_to reply_to if reply_to
    end

    mail.deliver!
    logger.info "Email sent to #{to}: #{subject}"
  end

  def check_rate_limit!
    state = settings.rate_limit_state

    # Reset if time window expired
    if Time.now >= state[:reset_at]
      state[:count] = 0
      state[:reset_at] = Time.now + 60
    end

    max_per_minute = ENV.fetch("RATE_LIMIT_PER_MINUTE", "20").to_i

    if state[:count] >= max_per_minute
      raise RateLimitError, "Rate limit exceeded (#{max_per_minute}/min)"
    end
  end

  def increment_rate_limit!
    settings.rate_limit_state[:count] += 1
  end

  def suppression_enabled?
    ENV.fetch("ENABLE_SUPPRESSION", "true") == "true"
  end

  def is_suppressed?(email)
    email = email.downcase.strip
    prefs = settings.email_preferences[email]
    prefs && prefs[:suppressed]
  end

  def default_preferences
    {
      suppressed: false,
      digest_only: false,
      frequency: "realtime"
    }
  end

  def smtp_configured?
    ENV["SMTP_USERNAME"].present? && ENV["SMTP_PASSWORD"].present?
  end

  def default_from_address
    ENV.fetch("EMAIL_FROM", "notifications@kiket.dev")
  end
end
