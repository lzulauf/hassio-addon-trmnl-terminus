# hassio-addon-trmnl-terminus

TRMNL Terminus add-on for Home Assistant.

## Status

This add-on is an experimental first pass.

It builds Terminus from source in a multi-stage Docker build, runs both the web
server and Sidekiq worker in one container, and now bundles PostgreSQL + Redis
inside the add-on container for a single-install setup.

The add-on image is built on top of the Home Assistant base image and installs
Terminus from source during build.

## Local Docker Compose test

For local validation outside Home Assistant, this repository includes
`docker-compose.yml` plus `compose/options.json`.

Start the add-on container locally:

```sh
docker compose up --build
```

Once services are healthy, open:

- `http://localhost:2300`

After first successful startup, setup is skipped automatically on future boots.
The add-on writes a marker file at `/config/.terminus_setup_complete`.

To force setup to run again, remove that marker file and restart.

To tear down and remove volumes:

```sh
docker compose down -v
```

## Build maintenance notes

The Dockerfile currently compiles Ruby 4.0.5 from source because Home Assistant
base does not currently provide Ruby >= 4.0.5 via `apk`.

To check whether source compilation can be removed in the future:

```sh
docker run --rm --entrypoint /bin/sh ghcr.io/home-assistant/base:latest -lc "apk update >/dev/null; apk policy ruby"
```

If that output shows Ruby 4.0.5 or newer, you can simplify the build by:

- Removing the `ruby-builder` stage from `Dockerfile`.
- Installing apk-provided Ruby in the build/final stages instead.
- Removing Ruby source build dependencies.

## Prerequisites

- An API URI that your TRMNL devices can reach.

## Configuration

- `api_uri`: Public URI used by your devices (for example,
  `http://homeassistant.local:2300`).
- `app_secret`: Optional. If empty, one is generated and saved to
  `/config/.app_secret`.
- `app_setup`: Enables one-time setup (assets compile + DB migration).
  When true, assets compile once and DB migrations run on every startup.
  Assets compile is skipped after `/config/.terminus_setup_complete` exists.
  Set to false to always skip setup.
- `certificate_urls`: Optional comma-separated certificate URLs for environments
  using self-signed certs.

## Bundled services

- PostgreSQL is initialized and persisted under `/config/postgres/data`.
- Redis is persisted under `/config/redis`.
- Internal PostgreSQL and Redis passwords are generated on first startup and
  persisted at `/config/.terminus_db_password` and
  `/config/.terminus_redis_password`.
- Terminus automatically connects to these bundled services using local-only
  endpoints.
- Startup uses root only for bootstrap tasks (such as ownership fixes on mounted
  storage), then runs long-lived services as non-root users (`postgres`,
  `redis`, and `app`).

## Persistence

- Uploaded files are persisted at `/config/uploads`.
- Generated app secret is persisted at `/config/.app_secret`.
- Setup completion marker is persisted at `/config/.terminus_setup_complete`.
