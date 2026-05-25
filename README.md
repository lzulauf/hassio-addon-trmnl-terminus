# hassio-addon-trmnl-terminus

TRMNL Terminus add-on for Home Assistant.

## Status

This add-on is an experimental first pass.

It wraps the official Terminus image, runs both the web server and Sidekiq worker
in one container, and expects PostgreSQL + Valkey/Redis to be available via
network URLs.

The add-on image is built on top of the Home Assistant base image and installs
Terminus from source during build.

## Prerequisites

- A reachable PostgreSQL instance.
- A reachable Valkey or Redis instance.
- An API URI that your TRMNL devices can reach.

## Configuration

- `api_uri`: Public URI used by your devices (for example,
  `http://homeassistant.local:2300`).
- `database_url`: PostgreSQL connection URL for Terminus.
- `keyvalue_url`: Valkey/Redis connection URL for Terminus.
- `app_secret`: Optional. If empty, one is generated and saved to
  `/config/.app_secret`.
- `app_setup`: Runs assets compilation and database migrations on boot when true.
  Set to false after first successful setup to reduce startup time.
- `certificate_urls`: Optional comma-separated certificate URLs for environments
  using self-signed certs.

## Persistence

- Uploaded files are persisted at `/config/uploads`.
- Generated app secret is persisted at `/config/.app_secret`.
