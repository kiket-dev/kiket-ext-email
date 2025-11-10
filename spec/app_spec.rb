# frozen_string_literal: true

require "spec_helper"

RSpec.describe EmailNotificationExtension do
  def app
    EmailNotificationExtension
  end

  describe "GET /health" do
    it "returns healthy status" do
      get "/health"

      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json["status"]).to eq("healthy")
      expect(json["service"]).to eq("email-notifications")
      expect(json["version"]).to eq("1.0.0")
    end
  end

  describe "POST /send" do
    context "with valid email request" do
      it "sends email successfully" do
        post "/send", JSON.generate({
          to: "user@example.com",
          subject: "Test Subject",
          body: "Test Body"
        }), { "CONTENT_TYPE" => "application/json" }

        expect(last_response).to be_ok
        json = JSON.parse(last_response.body)
        expect(json["success"]).to be true
        expect(json["to"]).to eq("user@example.com")
        expect(json["subject"]).to eq("Test Subject")

        # Check email was sent
        expect(Mail::TestMailer.deliveries.length).to eq(1)
        email = Mail::TestMailer.deliveries.first
        expect(email.to).to eq(["user@example.com"])
        expect(email.subject).to eq("Test Subject")
        expect(email.body.to_s).to eq("Test Body")
      end

      it "sends email with CC and BCC" do
        post "/send", JSON.generate({
          to: "user@example.com",
          subject: "Test",
          body: "Body",
          cc: "cc@example.com",
          bcc: "bcc@example.com"
        }), { "CONTENT_TYPE" => "application/json" }

        expect(last_response).to be_ok

        email = Mail::TestMailer.deliveries.first
        expect(email.cc).to eq(["cc@example.com"])
        expect(email.bcc).to eq(["bcc@example.com"])
      end
    end

    context "with template" do
      it "renders issue_created template" do
        post "/send", JSON.generate({
          to: "user@example.com",
          template: "issue_created",
          context: {
            issue: {
              title: "Bug in login",
              description: "Cannot login",
              priority: "high",
              status: "open",
              url: "https://example.com/issues/1"
            }
          }
        }), { "CONTENT_TYPE" => "application/json" }

        expect(last_response).to be_ok
        json = JSON.parse(last_response.body)
        expect(json["subject"]).to eq("New issue: Bug in login")

        email = Mail::TestMailer.deliveries.first
        expect(email.subject).to eq("New issue: Bug in login")
        expect(email.body.to_s).to include("Bug in login")
        expect(email.body.to_s).to include("Cannot login")
        expect(email.body.to_s).to include("high")
      end

      it "renders issue_assigned template" do
        post "/send", JSON.generate({
          to: "user@example.com",
          template: "issue_assigned",
          context: {
            issue: {
              title: "Fix bug",
              description: "Urgent fix needed",
              due_date: "2025-12-01",
              url: "https://example.com/issues/2"
            }
          }
        }), { "CONTENT_TYPE" => "application/json" }

        expect(last_response).to be_ok

        email = Mail::TestMailer.deliveries.first
        expect(email.subject).to eq("You've been assigned to: Fix bug")
        expect(email.body.to_s).to include("2025-12-01")
      end

      it "renders issue_transitioned template" do
        post "/send", JSON.generate({
          to: "user@example.com",
          template: "issue_transitioned",
          context: {
            issue: {
              title: "Deploy to production",
              url: "https://example.com/issues/3"
            },
            transition: {
              from: "in_progress",
              to: "done"
            },
            comment: "Deployment complete"
          }
        }), { "CONTENT_TYPE" => "application/json" }

        expect(last_response).to be_ok

        email = Mail::TestMailer.deliveries.first
        expect(email.subject).to eq("Issue updated: Deploy to production")
        expect(email.body.to_s).to include("in_progress")
        expect(email.body.to_s).to include("done")
        expect(email.body.to_s).to include("Deployment complete")
      end

      it "renders sla_breach template" do
        post "/send", JSON.generate({
          to: "oncall@example.com",
          template: "sla_breach",
          context: {
            issue: {
              title: "Critical bug",
              url: "https://example.com/issues/4"
            },
            sla: {
              name: "P0 Response Time"
            },
            breach: {
              timestamp: "2025-11-10T12:00:00Z"
            }
          }
        }), { "CONTENT_TYPE" => "application/json" }

        expect(last_response).to be_ok

        email = Mail::TestMailer.deliveries.first
        expect(email.subject).to include("SLA BREACH")
        expect(email.body.to_s).to include("P0 Response Time")
        expect(email.body.to_s).to include("Immediate action required")
      end

      it "returns error for unknown template" do
        post "/send", JSON.generate({
          to: "user@example.com",
          template: "unknown_template"
        }), { "CONTENT_TYPE" => "application/json" }

        expect(last_response.status).to eq(400)
        json = JSON.parse(last_response.body)
        expect(json["success"]).to be false
        expect(json["error"]).to include("not found")
      end
    end

    context "with validation errors" do
      it "requires recipient" do
        post "/send", JSON.generate({
          subject: "Test",
          body: "Body"
        }), { "CONTENT_TYPE" => "application/json" }

        expect(last_response.status).to eq(400)
        json = JSON.parse(last_response.body)
        expect(json["error"]).to include("Recipient")
      end

      it "validates email format" do
        post "/send", JSON.generate({
          to: "invalid-email",
          subject: "Test",
          body: "Body"
        }), { "CONTENT_TYPE" => "application/json" }

        expect(last_response.status).to eq(400)
        json = JSON.parse(last_response.body)
        expect(json["error"]).to include("Invalid email")
      end

      it "requires subject or template" do
        post "/send", JSON.generate({
          to: "user@example.com",
          body: "Body"
        }), { "CONTENT_TYPE" => "application/json" }

        expect(last_response.status).to eq(400)
        json = JSON.parse(last_response.body)
        expect(json["error"]).to include("subject")
      end

      it "handles invalid JSON" do
        post "/send", "invalid json", { "CONTENT_TYPE" => "application/json" }

        expect(last_response.status).to eq(400)
        json = JSON.parse(last_response.body)
        expect(json["error"]).to include("Invalid JSON")
      end
    end

    context "with rate limiting" do
      it "enforces rate limits" do
        # Send emails up to the limit
        21.times do |i|
          post "/send", JSON.generate({
            to: "user#{i}@example.com",
            subject: "Test",
            body: "Body"
          }), { "CONTENT_TYPE" => "application/json" }
        end

        # Last request should be rate limited
        expect(last_response.status).to eq(400)
        json = JSON.parse(last_response.body)
        expect(json["error"]).to include("Rate limit exceeded")
      end
    end

    context "with suppression" do
      it "suppresses email for opted-out users" do
        # Set user preference to suppressed
        post "/preferences/update", JSON.generate({
          email: "suppressed@example.com",
          suppressed: true
        }), { "CONTENT_TYPE" => "application/json" }

        # Try to send email
        post "/send", JSON.generate({
          to: "suppressed@example.com",
          subject: "Test",
          body: "Body"
        }), { "CONTENT_TYPE" => "application/json" }

        expect(last_response).to be_ok
        json = JSON.parse(last_response.body)
        expect(json["suppressed"]).to be true
        expect(json["reason"]).to include("opted out")

        # No email should be sent
        expect(Mail::TestMailer.deliveries.length).to eq(0)
      end
    end
  end

  describe "POST /digest/queue" do
    it "queues email for digest" do
      post "/digest/queue", JSON.generate({
        to: "user@example.com",
        template: "issue_created",
        context: {
          issue: { title: "Bug 1" }
        }
      }), { "CONTENT_TYPE" => "application/json" }

      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json["success"]).to be true
      expect(json["queued_count"]).to eq(1)
    end

    it "queues multiple emails for same recipient" do
      3.times do |i|
        post "/digest/queue", JSON.generate({
          to: "user@example.com",
          template: "issue_created",
          context: {
            issue: { title: "Bug #{i}" }
          }
        }), { "CONTENT_TYPE" => "application/json" }
      end

      json = JSON.parse(last_response.body)
      expect(json["queued_count"]).to eq(3)
    end
  end

  describe "POST /digest/send" do
    it "sends digest emails" do
      # Queue some emails
      post "/digest/queue", JSON.generate({
        to: "user1@example.com",
        template: "issue_created",
        context: {
          issue: { title: "Bug 1", url: "http://example.com/1" }
        }
      }), { "CONTENT_TYPE" => "application/json" }

      post "/digest/queue", JSON.generate({
        to: "user1@example.com",
        template: "issue_created",
        context: {
          issue: { title: "Bug 2", url: "http://example.com/2" }
        }
      }), { "CONTENT_TYPE" => "application/json" }

      post "/digest/queue", JSON.generate({
        to: "user2@example.com",
        template: "issue_created",
        context: {
          issue: { title: "Bug 3", url: "http://example.com/3" }
        }
      }), { "CONTENT_TYPE" => "application/json" }

      Mail::TestMailer.deliveries.clear

      # Send digests
      post "/digest/send"

      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json["success"]).to be true
      expect(json["digests_sent"]).to eq(2)

      # Check emails were sent
      expect(Mail::TestMailer.deliveries.length).to eq(2)

      user1_email = Mail::TestMailer.deliveries.find { |e| e.to.include?("user1@example.com") }
      expect(user1_email.subject).to include("2 updates")
    end

    it "clears digest queue after sending" do
      post "/digest/queue", JSON.generate({
        to: "user@example.com",
        template: "issue_created",
        context: { issue: { title: "Bug" } }
      }), { "CONTENT_TYPE" => "application/json" }

      post "/digest/send"

      # Send again - should be empty
      Mail::TestMailer.deliveries.clear
      post "/digest/send"

      expect(Mail::TestMailer.deliveries.length).to eq(0)
    end
  end

  describe "POST /preferences/update" do
    it "updates user preferences" do
      post "/preferences/update", JSON.generate({
        email: "user@example.com",
        suppressed: true,
        digest_only: true,
        frequency: "daily"
      }), { "CONTENT_TYPE" => "application/json" }

      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json["success"]).to be true
      expect(json["email"]).to eq("user@example.com")
      expect(json["preferences"]["suppressed"]).to be true
      expect(json["preferences"]["digest_only"]).to be true
      expect(json["preferences"]["frequency"]).to eq("daily")
    end

    it "normalizes email address" do
      post "/preferences/update", JSON.generate({
        email: " User@Example.COM ",
        suppressed: true
      }), { "CONTENT_TYPE" => "application/json" }

      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json["email"]).to eq("user@example.com")
    end

    it "requires email" do
      post "/preferences/update", JSON.generate({
        suppressed: true
      }), { "CONTENT_TYPE" => "application/json" }

      expect(last_response.status).to eq(400)
      json = JSON.parse(last_response.body)
      expect(json["error"]).to include("required")
    end
  end

  describe "POST /preferences/check" do
    it "returns user preferences" do
      # Set preferences first
      post "/preferences/update", JSON.generate({
        email: "user@example.com",
        digest_only: true
      }), { "CONTENT_TYPE" => "application/json" }

      # Check preferences
      post "/preferences/check", JSON.generate({
        email: "user@example.com"
      }), { "CONTENT_TYPE" => "application/json" }

      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json["success"]).to be true
      expect(json["preferences"]["digest_only"]).to be true
    end

    it "returns default preferences for unknown user" do
      post "/preferences/check", JSON.generate({
        email: "unknown@example.com"
      }), { "CONTENT_TYPE" => "application/json" }

      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json["preferences"]["suppressed"]).to be false
      expect(json["preferences"]["digest_only"]).to be false
      expect(json["preferences"]["frequency"]).to eq("realtime")
    end
  end

  describe "POST /template/validate" do
    it "validates valid template" do
      post "/template/validate", JSON.generate({
        template: "Hello {{ name }}, you have {{ count }} issues"
      }), { "CONTENT_TYPE" => "application/json" }

      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json["success"]).to be true
      expect(json["valid"]).to be true
    end

    it "rejects invalid template syntax" do
      post "/template/validate", JSON.generate({
        template: "Hello {{ name"
      }), { "CONTENT_TYPE" => "application/json" }

      expect(last_response.status).to eq(400)
      json = JSON.parse(last_response.body)
      expect(json["valid"]).to be false
      expect(json["error"]).to include("syntax")
    end
  end
end
