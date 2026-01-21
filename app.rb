# frozen_string_literal: true

require 'kiket_sdk'
require 'rackup'
require 'mail'
require 'liquid'
require 'logger'

# Email Notification Extension
# Handles sending email notifications with template support using Kiket SDK
class EmailNotificationExtension
  # Custom error classes
  class ValidationError < StandardError; end
  class TemplateError < StandardError; end
  class RateLimitError < StandardError; end

  REQUIRED_SEND_SCOPES = %w[notifications:send].freeze
  REQUIRED_PREFERENCES_SCOPES = %w[users:read].freeze

  def initialize
    @sdk = KiketSDK.new
    @logger = Logger.new($stdout)
    @email_preferences = {}
    @digest_queue = {}
    @rate_limit_state = { count: 0, reset_at: Time.now + 60 }

    configure_mail
    setup_handlers
  end

  def app
    @sdk
  end

  private

  def configure_mail
    base_domain = ENV.fetch('KIKET_BASE_DOMAIN', 'kiket.dev')

    Mail.defaults do
      delivery_method :smtp, {
        address: ENV.fetch('SMTP_HOST', 'smtp.gmail.com'),
        port: ENV.fetch('SMTP_PORT', '587').to_i,
        domain: ENV.fetch('SMTP_DOMAIN', base_domain),
        user_name: ENV.fetch('SMTP_USERNAME', nil),
        password: ENV.fetch('SMTP_PASSWORD', nil),
        authentication: ENV.fetch('SMTP_AUTH', 'plain').to_sym,
        enable_starttls_auto: ENV.fetch('SMTP_TLS', 'true') == 'true'
      }
    end
  end

  def setup_handlers
    # Send email notification
    @sdk.register('email.send', version: 'v1', required_scopes: REQUIRED_SEND_SCOPES) do |payload, context|
      handle_send_email(payload, context)
    end

    # Queue email for digest delivery
    @sdk.register('email.digest.queue', version: 'v1', required_scopes: REQUIRED_SEND_SCOPES) do |payload, context|
      handle_digest_queue(payload, context)
    end

    # Send digest emails
    @sdk.register('email.digest.send', version: 'v1', required_scopes: REQUIRED_SEND_SCOPES) do |payload, context|
      handle_digest_send(payload, context)
    end

    # Update email preferences
    @sdk.register('email.preferences.update', version: 'v1', required_scopes: REQUIRED_PREFERENCES_SCOPES) do |payload, context|
      handle_preferences_update(payload, context)
    end

    # Check email preferences
    @sdk.register('email.preferences.check', version: 'v1', required_scopes: REQUIRED_PREFERENCES_SCOPES) do |payload, context|
      handle_preferences_check(payload, context)
    end

    # Validate email template
    @sdk.register('email.template.validate', version: 'v1', required_scopes: []) do |payload, context|
      handle_template_validate(payload, context)
    end
  end

  def handle_send_email(payload, context)
    # Validate required fields
    validate_email_request!(payload)

    # Check rate limiting
    check_rate_limit!

    # Get SMTP credentials from secrets (per-org or ENV fallback)
    smtp_username = context[:secret].call('SMTP_USERNAME')
    smtp_password = context[:secret].call('SMTP_PASSWORD')

    # Check email preferences
    if suppression_enabled? && is_suppressed?(payload['to'])
      @logger.info "Email suppressed for #{payload['to']} per user preferences"
      return {
        success: true,
        suppressed: true,
        to: payload['to'],
        reason: 'User has opted out of email notifications'
      }
    end

    # Render template if provided
    subject, body = render_email(payload)

    # Send email
    send_email(
      to: payload['to'],
      subject: subject,
      body: body,
      from: payload['from'] || default_from_address,
      cc: payload['cc'],
      bcc: payload['bcc'],
      reply_to: payload['reply_to'],
      smtp_username: smtp_username,
      smtp_password: smtp_password
    )

    # Increment rate limit counter
    increment_rate_limit!

    # Log telemetry event
    context[:endpoints].log_event('email.sent', {
                                    to: payload['to'],
                                    subject: subject,
                                    org_id: context[:auth][:org_id]
                                  })

    {
      success: true,
      to: payload['to'],
      subject: subject,
      sent_at: Time.now.utc.iso8601
    }
  rescue ValidationError, TemplateError, RateLimitError => e
    @logger.error "Error: #{e.message}"
    { success: false, error: e.message }
  rescue StandardError => e
    @logger.error "SMTP error: #{e.message}"
    @logger.error e.backtrace.join("\n")
    { success: false, error: "Email delivery error: #{e.message}" }
  end

  def handle_digest_queue(payload, _context)
    validate_email_request!(payload)

    recipient = payload['to']
    @digest_queue[recipient] ||= []
    @digest_queue[recipient] << {
      template: payload['template'],
      context: payload['context'],
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

  def handle_digest_send(_payload, context)
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

    context[:endpoints].log_event('email.digest.sent', {
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
    @logger.error "Digest send error: #{e.message}"
    { success: false, error: e.message }
  end

  def handle_preferences_update(payload, _context)
    raise ValidationError, 'Email address is required' unless payload['email']

    email = payload['email'].downcase.strip
    @email_preferences[email] = {
      suppressed: payload['suppressed'] || false,
      digest_only: payload['digest_only'] || false,
      frequency: payload['frequency'] || 'realtime',
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

  def handle_preferences_check(payload, _context)
    raise ValidationError, 'Email address is required' unless payload['email']

    email = payload['email'].downcase.strip
    preferences = @email_preferences[email] || default_preferences

    {
      success: true,
      email: email,
      preferences: preferences
    }
  rescue ValidationError => e
    { success: false, error: e.message }
  end

  def handle_template_validate(payload, _context)
    raise ValidationError, 'Template body is required' unless payload['template']

    Liquid::Template.parse(payload['template'])

    {
      success: true,
      valid: true,
      message: 'Template syntax is valid'
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

  # Helper methods

  def validate_email_request!(payload)
    raise ValidationError, 'Recipient (to) is required' unless payload['to']
    raise ValidationError, 'Invalid email address' unless valid_email?(payload['to'])

    raise ValidationError, 'Either template or subject is required' if payload['template'].nil? && payload['subject'].nil?

    return unless payload['template'].nil? && payload['body'].nil?

    raise ValidationError, 'Either template or body is required'
  end

  def valid_email?(email)
    email.to_s.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
  end

  def render_email(payload)
    if payload['template']
      template_name = payload['template'].to_sym
      template = default_templates[template_name]

      raise TemplateError, "Template '#{template_name}' not found" unless template

      template_context = payload['context'] || {}

      subject_template = Liquid::Template.parse(template[:subject])
      body_template = Liquid::Template.parse(template[:body])

      subject = subject_template.render(stringify_keys(template_context))
      body = body_template.render(stringify_keys(template_context))

      [subject, body]
    else
      [payload['subject'], payload['body']]
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
                      'count' => emails.length,
                      'emails' => emails.map do |e|
                        _, body = render_email('template' => e[:template], 'context' => e[:context])
                        { 'rendered_body' => body }
                      end
                    })
  end

  def send_email(to:, subject:, body:, from:, cc: nil, bcc: nil, reply_to: nil, smtp_username: nil, smtp_password: nil)
    mail = Mail.new do
      to to
      from from
      subject subject
      body body
      cc cc if cc
      bcc bcc if bcc
      reply_to reply_to if reply_to
    end

    # Configure delivery settings if custom credentials provided
    if smtp_username && smtp_password
      mail.delivery_method :smtp, {
        address: ENV.fetch('SMTP_HOST', 'smtp.gmail.com'),
        port: ENV.fetch('SMTP_PORT', '587').to_i,
        user_name: smtp_username,
        password: smtp_password,
        authentication: ENV.fetch('SMTP_AUTH', 'plain').to_sym,
        enable_starttls_auto: ENV.fetch('SMTP_TLS', 'true') == 'true'
      }
    end

    mail.deliver!
    @logger.info "Email sent to #{to}: #{subject}"
  end

  def check_rate_limit!
    if Time.now >= @rate_limit_state[:reset_at]
      @rate_limit_state[:count] = 0
      @rate_limit_state[:reset_at] = Time.now + 60
    end

    max_per_minute = ENV.fetch('RATE_LIMIT_PER_MINUTE', '20').to_i

    return unless @rate_limit_state[:count] >= max_per_minute

    raise RateLimitError, "Rate limit exceeded (#{max_per_minute}/min)"
  end

  def increment_rate_limit!
    @rate_limit_state[:count] += 1
  end

  def suppression_enabled?
    ENV.fetch('ENABLE_SUPPRESSION', 'true') == 'true'
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
      frequency: 'realtime'
    }
  end

  def default_from_address
    base_domain = ENV.fetch('KIKET_BASE_DOMAIN', 'kiket.dev')
    ENV.fetch('EMAIL_FROM', "notifications@#{base_domain}")
  end

  def default_templates
    {
      issue_created: {
        subject: 'New issue: {{ issue.title }}',
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
        subject: 'Issue updated: {{ issue.title }}',
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
        subject: 'SLA BREACH: {{ issue.title }}',
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
end

# Run the extension
if __FILE__ == $PROGRAM_NAME
  extension = EmailNotificationExtension.new

  Rackup::Handler.get(:puma).run(
    extension.app,
    Host: ENV.fetch('HOST', '0.0.0.0'),
    Port: ENV.fetch('PORT', 8080).to_i,
    Threads: '0:16'
  )
end
