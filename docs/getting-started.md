# Getting Started with Email Notifications

Send email notifications from your Kiket workflows with customizable templates, digest mode, and user preference management.

## Prerequisites

- SMTP server credentials (or email service like SendGrid, Mailgun, AWS SES)
- A Kiket project with workflows configured

## Step 1: Gather SMTP Credentials

You'll need the following from your email provider:

| Setting | Example (SendGrid) | Example (Mailgun) |
|---------|-------------------|-------------------|
| SMTP Host | smtp.sendgrid.net | smtp.mailgun.org |
| SMTP Port | 587 | 587 |
| Username | apikey | postmaster@domain |
| Password | Your API key | Your SMTP password |

## Step 2: Install the Extension

1. Go to **Organization Settings → Extensions → Marketplace**
2. Find "Email Notifications" and click **Install**
3. Enter your SMTP credentials:
   - **SMTP Host**: Your email server hostname
   - **SMTP Username**: Authentication username
   - **SMTP Password**: Authentication password
   - **From Address**: Default sender address

4. Click **Test Connection** to verify settings

## Step 3: Configure Email Templates

The extension includes default templates for common events. Customize them:

1. Go to **Project Settings → Extensions → Email**
2. Edit templates using Liquid syntax
3. Preview with sample data before saving

### Available Variables

Templates have access to these variables:

- `issue` - The issue object (title, type, priority, url, etc.)
- `user` - The recipient user
- `project` - The project details
- `assignee` - The assigned user (for assignment notifications)
- `comment` - Comment details (for comment notifications)
- `sla` - SLA breach details (for SLA alerts)

### Example Template

```liquid
<h2>{{ issue.title }}</h2>
<p>Priority: {{ issue.priority | default: "Normal" }}</p>
<p>
  <a href="{{ issue.url }}" style="background: #007bff; color: white; padding: 10px 20px; text-decoration: none;">
    View Issue
  </a>
</p>
```

## Step 4: Add Email Actions to Workflows

```yaml
automations:
  - name: email_on_high_priority
    trigger:
      event: issue.created
      conditions:
        - field: issue.priority
          operator: eq
          value: "critical"
    actions:
      - extension: dev.kiket.ext.email
        command: email.send
        params:
          to: "{{ issue.assignee.email }}"
          subject: "[URGENT] {{ issue.title }}"
          template: sla_breach_template
```

## Step 5: Enable Digest Mode (Optional)

Reduce notification fatigue by batching emails:

1. Go to **Project Settings → Extensions → Email**
2. Enable **Digest Mode**
3. Configure frequency (hourly, daily, or weekly)
4. Users receive a single summary email instead of individual notifications

## User Preferences

Users can manage their email preferences:

1. Click the profile menu → **Notification Preferences**
2. Enable/disable specific notification types
3. Choose between immediate or digest delivery
4. Opt out of specific projects

## Next Steps

- [View example workflows](./examples/)
- Set up SLA breach alerts
- Configure digest schedules
- Customize email branding
