#!/usr/bin/env bash
set -euo pipefail

OPTIONS_FILE="/data/options.json"

read_required_option() {
    local key="$1"

    jq -er --arg key "${key}" '.[$key] | select(type == "string" and length > 0)' "${OPTIONS_FILE}"
}

run_as_app() {
    local command="$1"

    if id app >/dev/null 2>&1; then
        su -s /bin/bash app -c "${command}"
    else
        sh -c "${command}"
    fi
}

if [[ ! -f "${OPTIONS_FILE}" ]]; then
    echo "Unable to find add-on options file at ${OPTIONS_FILE}."
    exit 1
fi

API_URI="$(read_required_option "api_uri")"
DATABASE_URL="$(read_required_option "database_url")"
KEYVALUE_URL="$(read_required_option "keyvalue_url")"
APP_SETUP="$(jq -er '.app_setup // true' "${OPTIONS_FILE}")"
CERTIFICATE_URLS="$(jq -er '.certificate_urls // empty' "${OPTIONS_FILE}")"
APP_SECRET="$(jq -er '.app_secret // empty' "${OPTIONS_FILE}")"

if [[ -z "${APP_SECRET}" ]]; then
    if [[ -s /config/.app_secret ]]; then
        APP_SECRET="$(cat /config/.app_secret)"
    else
        APP_SECRET="$(ruby -e 'require "securerandom"; print SecureRandom.hex(64)')"
        printf '%s' "${APP_SECRET}" > /config/.app_secret
    fi
fi

mkdir -p /config/uploads

if [[ -d /app/public/uploads && ! -L /app/public/uploads ]]; then
    cp -an /app/public/uploads/. /config/uploads/ 2>/dev/null || true
    rm -rf /app/public/uploads
fi

if [[ ! -L /app/public/uploads ]]; then
    ln -s /config/uploads /app/public/uploads
fi

if id app >/dev/null 2>&1; then
    chown -R app:app /config/uploads
    chown app:app /config/.app_secret
fi

export API_URI
export APP_SECRET
export CERTIFICATE_URLS
export DATABASE_URL
export HANAMI_PORT="2300"
export KEYVALUE_URL

if [[ -n "${CERTIFICATE_URLS}" ]]; then
    scripts/docker/install-certificates
fi

if [[ "${APP_SETUP}" == "true" ]]; then
    echo "Running Terminus setup tasks..."
    run_as_app "bundle exec hanami assets compile"
    run_as_app "bundle exec hanami db migrate"
else
    echo "Skipping Terminus setup tasks because app_setup is false."
fi

echo "Starting Terminus web server and Sidekiq worker..."

if id app >/dev/null 2>&1; then
    exec su -s /bin/bash app -c "bundle exec puma --config ./config/puma.rb & bundle exec sidekiq -r ./config/sidekiq.rb & wait"
fi

exec sh -c "bundle exec puma --config ./config/puma.rb & bundle exec sidekiq -r ./config/sidekiq.rb & wait"
