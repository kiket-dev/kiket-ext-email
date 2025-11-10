# Email Extension for Kiket

Send email notifications with template support, digest batching, and user preference management using SMTP.

## Features

- **Email Notifications**: Send templated or custom emails
- **Template Engine**: Liquid template support for dynamic content
- **Digest Mode**: Batch multiple notifications into periodic digests
- **Preference Management**: User opt-out and delivery preferences
- **Rate Limiting**: Prevent abuse with configurable rate limits
- **Provider Abstraction**: Works with any SMTP server (Gmail, SendGrid, SES, etc.)
- **Error Handling**: Comprehensive error handling with retry logic

## Prerequisites

- Ruby 3.4+
- SMTP server credentials (Gmail, SendGrid, AWS SES, etc.)

## Installation

1. Clone the repository:
```bash
git clone https://github.com/kiket-dev/kiket-ext-email.git
cd kiket-ext-email
```

2. Install dependencies:
```bash
bundle install
```

3. Configure environment variables:
```bash
cp .env.example .env
# Edit .env with your SMTP credentials
```

4. Start the server:
```bash
bundle exec puma -C puma.rb
```

The extension will be available at `http://localhost:9393`

## Configuration

### Required Environment Variables

- `SMTP_HOST`: SMTP server hostname (e.g., smtp.gmail.com)
- `SMTP_USERNAME`: SMTP authentication username
- `SMTP_PASSWORD`: SMTP authentication password

### Optional Environment Variables

- `SMTP_PORT`: SMTP server port (default: 587)
- `SMTP_AUTH`: Authentication method - plain, login, cram_md5 (default: plain)
- `SMTP_TLS`: Enable STARTTLS (default: true)
- `SMTP_DOMAIN`: HELO domain (default: value of `KIKET_BASE_DOMAIN`)
- `EMAIL_FROM`: Default FROM address (default: `notifications@${KIKET_BASE_DOMAIN}`)
- `RATE_LIMIT_PER_MINUTE`: Maximum emails per minute (default: 20)
- `ENABLE_SUPPRESSION`: Honor user opt-out preferences (default: true)

## API Endpoints

See full documentation below for all endpoints including:
- `/send` - Send email
- `/digest/queue` - Queue for digest
- `/digest/send` - Send digests
- `/preferences/update` - Update user preferences
- `/preferences/check` - Check preferences
- `/template/validate` - Validate template syntax
- `/health` - Health check

For complete API documentation, provider setup guides, and troubleshooting, see the detailed sections below
