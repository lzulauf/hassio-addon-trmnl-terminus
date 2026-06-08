# hassio-addon-trmnl-terminus

TRMNL Terminus add-on for Home Assistant.

Run a self-hosted TRMNL Terminus server inside Home Assistant so your TRMNL
devices can connect to infrastructure you control.

Use this add-on to:

- Connect TRMNL devices to your own Terminus server.
- Manage device registrations, screens, and playlists on your own instance.
- Keep device data and server state local to your Home Assistant environment.

- Upstream Terminus project: [usetrmnl/terminus](https://github.com/usetrmnl/terminus)
- TRMNL website: [trmnl.com](https://trmnl.com)

## Home Assistant Usage

### Prerequisites

- An `api_uri` that your TRMNL devices can reach.

### Configuration

- `api_uri`: Public URI used by your devices (for example,
  `http://homeassistant.local:2300`). This should match exactly what your
  devices can access.
- `app_secret`: Optional. If empty, one is generated automatically and saved to
  `/config/.app_secret`. Recommended: leave this empty.
- `app_setup`: Enables setup tasks (asset setup + DB migration) at startup.
  Recommended: keep `true`.
- `certificate_urls`: Optional comma-separated certificate URLs for environments
  using private or self-signed certs. Recommended: leave empty unless needed.

### Connect A TRMNL Device

You do not need Developer Mode to use this add-on.

To point a TRMNL device at your Terminus server:

1. Start the add-on and confirm your `api_uri` is reachable from your local
  network.
2. Put your TRMNL device in Wi-Fi pairing mode.
3. Join the temporary Wi-Fi network broadcast by the device (name includes
  `TRMNL`) and open its captive portal.
4. In the portal, open Advanced, enable Custom Server, and enter your
  `api_uri` exactly.
5. Do not include a trailing slash in the server URL.
6. Return to Wi-Fi setup, select your SSID, enter the password, and connect.
7. After the device reboots, it should auto-register in Terminus.

If the device does not register, verify that `api_uri` matches exactly what the
device can reach and that port 2300 is accessible on your network.

### First Startup Behavior

- The add-on bundles PostgreSQL and Redis and configures Terminus to use them.
- On first startup, setup tasks run and a marker file is written to
  `/config/.terminus_setup_complete`.
- On future startups, asset setup is skipped once that marker exists.

### Persistence

- Uploaded files are persisted at `/config/uploads`.
- Generated app secret is persisted at `/config/.app_secret`.
- Setup completion marker is persisted at `/config/.terminus_setup_complete`.
- PostgreSQL data is persisted under `/config/postgres/data`.
- Redis data is persisted under `/config/redis`.
- Internal PostgreSQL and Redis passwords are generated on first startup and
  persisted at `/config/.terminus_db_password` and
  `/config/.terminus_redis_password`.

### Runtime Model

- Terminus web server and Sidekiq worker run in the same add-on container.
- Startup uses root only for bootstrap tasks, then long-lived services run as
  non-root users (`postgres`, `redis`, and `app`).

## Status

This add-on is an experimental first pass.

## Development And Maintenance

### Local Docker Compose Test

For local validation outside Home Assistant, this repository includes
`docker-compose.yml` plus `compose/options.json`.

Start the add-on container locally:

```sh
docker compose up --build
```

Once services are healthy, open:

- `http://localhost:2300`

To force setup to run again, remove `/config/.terminus_setup_complete` and
restart.

To tear down and remove volumes:

```sh
docker compose down -v
```

### Build Maintenance Notes

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
