# frozen_string_literal: true

ENV["RACK_ENV"] = "test"

require "bundler/setup"
Bundler.require(:default, :test)

require "rspec"
require "webmock/rspec"
require "mail"
require "liquid"
require "logger"

# Test-only class that includes the handler logic without SDK initialization
# This allows us to test the business logic in isolation
class TestEmailHandlers
  class ValidationError < StandardError; end
  class TemplateError < StandardError; end
  class RateLimitError < StandardError; end

  def initialize
    @logger = Logger.new($stdout)
    @logger.level = Logger::WARN # Reduce noise in tests
    @email_preferences = {}
    @digest_queue = {}
    @rate_limit_state = { count: 0, reset_at: Time.now + 60 }
  end

  def handle_send_email(payload, context)
    validate_email_request!(payload)
    check_rate_limit!

    if suppression_enabled? && is_suppressed?(payload["to"])
      return {
        success: true,
        suppressed: true,
        to: payload["to"],
        reason: "User has opted out of email notifications"
      }
    end

    subject, body = render_email(payload)

    send_email(
      to: payload["to"],
      subject: subject,
      body: body,
      from: payload["from"] || default_from_address,
      cc: payload["cc"],
      bcc: payload["bcc"]
    )

    increment_rate_limit!

    context[:endpoints].log_event.call("email.sent", {
      to: payload["to"],
      subject: subject,
      org_id: context[:auth][:org_id]
    })

    {
      success: true,
      to: payload["to"],
      subject: subject,
      sent_at: Time.now.utc.iso8601
    }
  rescue ValidationError, TemplateError, RateLimitError => e
    { success: false, error: e.message }
  rescue StandardError => e
    { success: false, error: "Email delivery error: #{e.message}" }
  end

  def handle_digest_queue(payload, context)
    validate_email_request!(payload)

    recipient = payload["to"]
    @digest_queue[recipient] ||= []
    @digest_queue[recipient] << {
      template: payload["template"],
      context: payload["context"],
      queued_at: Time.now.utc
    }

    {
      success: true,
      to: recipient,
      queued_count: @digest_queue[recipient].length,
      queued_at: Time.now.utc.iso8601
    }
  rescue ValidationError => e
    { success: false, error: e.message }
  end

  def handle_digest_send(payload, context)
    sent_digests = []

    @digest_queue.each do |recipient, emails|
      next if emails.empty?

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

    @digest_queue.clear

    context[:endpoints].log_event.call("email.digest.sent", {
      count: sent_digests.length,
      org_id: context[:auth][:org_id]
    })

    {
      success: true,
      digests_sent: sent_digests.length,
      sent_at: Time.now.utc.iso8601,
      digests: sent_digests
    }
  rescue StandardError => e
    { success: false, error: e.message }
  end

  def handle_preferences_update(payload, context)
    raise ValidationError, "Email address is required" unless payload["email"]

    email = payload["email"].downcase.strip
    @email_preferences[email] = {
      suppressed: payload["suppressed"] || false,
      digest_only: payload["digest_only"] || false,
      frequency: payload["frequency"] || "realtime",
      updated_at: Time.now.utc
    }

    {
      success: true,
      email: email,
      preferences: @email_preferences[email],
      updated_at: Time.now.utc.iso8601
    }
  rescue ValidationError => e
    { success: false, error: e.message }
  end

  def handle_preferences_check(payload, context)
    raise ValidationError, "Email address is required" unless payload["email"]

    email = payload["email"].downcase.strip
    preferences = @email_preferences[email] || default_preferences

    {
      success: true,
      email: email,
      preferences: preferences
    }
  rescue ValidationError => e
    { success: false, error: e.message }
  end

  def handle_template_validate(payload, context)
    raise ValidationError, "Template body is required" unless payload["template"]

    Liquid::Template.parse(payload["template"])

    {
      success: true,
      valid: true,
      message: "Template syntax is valid"
    }
  rescue Liquid::SyntaxError => e
    {
      success: false,
      valid: false,
      error: "Invalid template syntax: #{e.message}"
    }
  rescue ValidationError => e
    { success: false, error: e.message }
  end

  private

  def validate_email_request!(payload)
    raise ValidationError, "Recipient (to) is required" unless payload["to"]
    raise ValidationError, "Invalid email address" unless valid_email?(payload["to"])

    if payload["template"].nil? && payload["subject"].nil?
      raise ValidationError, "Either template or subject is required"
    end

    if payload["template"].nil? && payload["body"].nil?
      raise ValidationError, "Either template or body is required"
    end
  end

  def valid_email?(email)
    email.to_s.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
  end

  def render_email(payload)
    if payload["template"]
      template_name = payload["template"].to_sym
      template = default_templates[template_name]

      raise TemplateError, "Template '#{template_name}' not found" unless template

      template_context = payload["context"] || {}

      subject_template = Liquid::Template.parse(template[:subject])
      body_template = Liquid::Template.parse(template[:body])

      subject = subject_template.render(stringify_keys(template_context))
      body = body_template.render(stringify_keys(template_context))

      [subject, body]
    else
      [payload["subject"], payload["body"]]
    end
  end

  def stringify_keys(hash)
    hash.transform_keys(&:to_s)
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
        _, body = render_email("template" => e[:template], "context" => e[:context])
        { "rendered_body" => body }
      }
    })
  end

  def send_email(to:, subject:, body:, from:, cc: nil, bcc: nil)
    mail = Mail.new do
      to to
      from from
      subject subject
      body body
      cc cc if cc
      bcc bcc if bcc
    end

    mail.deliver!
  end

  def check_rate_limit!
    if Time.now >= @rate_limit_state[:reset_at]
      @rate_limit_state[:count] = 0
      @rate_limit_state[:reset_at] = Time.now + 60
    end

    max_per_minute = ENV.fetch("RATE_LIMIT_PER_MINUTE", "20").to_i

    if @rate_limit_state[:count] >= max_per_minute
      raise RateLimitError, "Rate limit exceeded (#{max_per_minute}/min)"
    end
  end

  def increment_rate_limit!
    @rate_limit_state[:count] += 1
  end

  def suppression_enabled?
    ENV.fetch("ENABLE_SUPPRESSION", "true") == "true"
  end

  def is_suppressed?(email)
    email = email.downcase.strip
    prefs = @email_preferences[email]
    prefs && prefs[:suppressed]
  end

  def default_preferences
    {
      suppressed: false,
      digest_only: false,
      frequency: "realtime"
    }
  end

  def default_from_address
    base_domain = ENV.fetch("KIKET_BASE_DOMAIN", "kiket.dev")
    ENV.fetch("EMAIL_FROM", "notifications@#{base_domain}")
  end

  def default_templates
    {
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
      }
    }
  end
end

# Mock context for SDK handler testing
def build_context(overrides = {})
  events_logged = []

  default_secrets = {
    "SMTP_USERNAME" => "test@example.com",
    "SMTP_PASSWORD" => "test_password"
  }

  {
    auth: { org_id: "test-org-123", user_id: "test-user-456" },
    secret: ->(key) { default_secrets[key] || ENV[key] },
    endpoints: double("endpoints", log_event: ->(event, data) { events_logged << { event: event, data: data } }),
    events_logged: events_logged
  }.merge(overrides)
end

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = "spec/examples.txt"
  config.disable_monkey_patching!
  config.warnings = false # Reduce noise from dependencies
  config.order = :random
  Kernel.srand config.seed

  # Clear Mail deliveries before each test
  config.before(:each) do
    Mail::TestMailer.deliveries.clear
  end

  # Use test mailer for all tests
  config.before(:suite) do
    Mail.defaults do
      delivery_method :test
    end
  end
end
