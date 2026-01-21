# frozen_string_literal: true

require 'spec_helper'

# Test the email handler logic without instantiating the full SDK
# The SDK has an issue with route definition in test context
RSpec.describe 'EmailNotificationExtension Handlers' do
  # Create a test-only class that includes the handler logic
  let(:test_extension) { TestEmailHandlers.new }
  let(:context) { build_context }

  before do
    Mail.defaults do
      delivery_method :test
    end
    Mail::TestMailer.deliveries.clear
  end

  describe '#handle_send_email' do
    context 'with valid email request' do
      it 'sends email successfully' do
        payload = {
          'to' => 'user@example.com',
          'subject' => 'Test Subject',
          'body' => 'Test Body'
        }

        result = test_extension.handle_send_email(payload, context)

        expect(result[:success]).to be true
        expect(result[:to]).to eq('user@example.com')
        expect(result[:subject]).to eq('Test Subject')

        expect(Mail::TestMailer.deliveries.length).to eq(1)
        email = Mail::TestMailer.deliveries.first
        expect(email.to).to eq(['user@example.com'])
        expect(email.subject).to eq('Test Subject')
        expect(email.body.to_s).to eq('Test Body')
      end

      it 'sends email with CC and BCC' do
        payload = {
          'to' => 'user@example.com',
          'subject' => 'Test',
          'body' => 'Body',
          'cc' => 'cc@example.com',
          'bcc' => 'bcc@example.com'
        }

        result = test_extension.handle_send_email(payload, context)

        expect(result[:success]).to be true

        email = Mail::TestMailer.deliveries.first
        expect(email.cc).to eq(['cc@example.com'])
        expect(email.bcc).to eq(['bcc@example.com'])
      end
    end

    context 'with template' do
      it 'renders issue_created template' do
        payload = {
          'to' => 'user@example.com',
          'template' => 'issue_created',
          'context' => {
            'issue' => {
              'title' => 'Bug in login',
              'description' => 'Cannot login',
              'priority' => 'high',
              'status' => 'open',
              'url' => 'https://example.com/issues/1'
            }
          }
        }

        result = test_extension.handle_send_email(payload, context)

        expect(result[:success]).to be true
        expect(result[:subject]).to eq('New issue: Bug in login')

        email = Mail::TestMailer.deliveries.first
        expect(email.subject).to eq('New issue: Bug in login')
        expect(email.body.to_s).to include('Bug in login')
        expect(email.body.to_s).to include('Cannot login')
        expect(email.body.to_s).to include('high')
      end

      it 'returns error for unknown template' do
        payload = {
          'to' => 'user@example.com',
          'template' => 'unknown_template'
        }

        result = test_extension.handle_send_email(payload, context)

        expect(result[:success]).to be false
        expect(result[:error]).to include('not found')
      end
    end

    context 'with validation errors' do
      it 'requires recipient' do
        payload = {
          'subject' => 'Test',
          'body' => 'Body'
        }

        result = test_extension.handle_send_email(payload, context)

        expect(result[:success]).to be false
        expect(result[:error]).to include('Recipient')
      end

      it 'validates email format' do
        payload = {
          'to' => 'invalid-email',
          'subject' => 'Test',
          'body' => 'Body'
        }

        result = test_extension.handle_send_email(payload, context)

        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid email')
      end

      it 'requires subject or template' do
        payload = {
          'to' => 'user@example.com',
          'body' => 'Body'
        }

        result = test_extension.handle_send_email(payload, context)

        expect(result[:success]).to be false
        expect(result[:error]).to include('subject')
      end
    end
  end

  describe '#handle_digest_queue' do
    it 'queues email for digest' do
      payload = {
        'to' => 'user@example.com',
        'template' => 'issue_created',
        'context' => {
          'issue' => { 'title' => 'Bug 1' }
        }
      }

      result = test_extension.handle_digest_queue(payload, context)

      expect(result[:success]).to be true
      expect(result[:queued_count]).to eq(1)
    end
  end

  describe '#handle_digest_send' do
    it 'sends digest emails' do
      # Queue some emails
      test_extension.handle_digest_queue({
                                           'to' => 'user1@example.com',
                                           'template' => 'issue_created',
                                           'context' => {
                                             'issue' => { 'title' => 'Bug 1', 'url' => 'http://example.com/1' }
                                           }
                                         }, context)

      test_extension.handle_digest_queue({
                                           'to' => 'user1@example.com',
                                           'template' => 'issue_created',
                                           'context' => {
                                             'issue' => { 'title' => 'Bug 2', 'url' => 'http://example.com/2' }
                                           }
                                         }, context)

      # Send digests
      result = test_extension.handle_digest_send({}, context)

      expect(result[:success]).to be true
      expect(result[:digests_sent]).to eq(1)

      expect(Mail::TestMailer.deliveries.length).to eq(1)
    end
  end

  describe '#handle_preferences_update' do
    it 'updates user preferences' do
      payload = {
        'email' => 'user@example.com',
        'suppressed' => true,
        'digest_only' => true,
        'frequency' => 'daily'
      }

      result = test_extension.handle_preferences_update(payload, context)

      expect(result[:success]).to be true
      expect(result[:email]).to eq('user@example.com')
      expect(result[:preferences][:suppressed]).to be true
    end

    it 'normalizes email address' do
      payload = {
        'email' => ' User@Example.COM ',
        'suppressed' => true
      }

      result = test_extension.handle_preferences_update(payload, context)

      expect(result[:success]).to be true
      expect(result[:email]).to eq('user@example.com')
    end

    it 'requires email' do
      payload = { 'suppressed' => true }

      result = test_extension.handle_preferences_update(payload, context)

      expect(result[:success]).to be false
      expect(result[:error]).to include('required')
    end
  end

  describe '#handle_preferences_check' do
    it 'returns default preferences for unknown user' do
      result = test_extension.handle_preferences_check({
                                                         'email' => 'unknown@example.com'
                                                       }, context)

      expect(result[:success]).to be true
      expect(result[:preferences][:suppressed]).to be false
      expect(result[:preferences][:frequency]).to eq('realtime')
    end
  end

  describe '#handle_template_validate' do
    it 'validates valid template' do
      payload = {
        'template' => 'Hello {{ name }}, you have {{ count }} issues'
      }

      result = test_extension.handle_template_validate(payload, context)

      expect(result[:success]).to be true
      expect(result[:valid]).to be true
    end

    it 'rejects invalid template syntax' do
      payload = {
        'template' => 'Hello {{ name'
      }

      result = test_extension.handle_template_validate(payload, context)

      expect(result[:valid]).to be false
      expect(result[:error]).to include('syntax')
    end
  end
end
