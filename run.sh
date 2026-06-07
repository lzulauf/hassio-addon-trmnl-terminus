#!/usr/bin/env bash
set -euo pipefail

OPTIONS_FILE="/data/options.json"
POSTGRES_DATA_DIR="/config/postgres/data"
POSTGRES_RUNTIME_DIR="/run/postgresql"
REDIS_DATA_DIR="/config/redis"
SETUP_MARKER_FILE="/config/.terminus_setup_complete"
MIGRATION_MARKER_FILE="/config/.terminus_last_migrated_gemfile_lock_sha256"
SETUP_HELPER_FILE="/opt/addon/lib/setup.sh"
POSTGRES_BOOTSTRAP_SQL_FILE="/opt/addon/sql/bootstrap-postgres.sql"
TERMINUS_DB_PASSWORD_FILE="/config/.terminus_db_password"
TERMINUS_KEYVALUE_PASSWORD_FILE="/config/.terminus_redis_password"

TERMINUS_DB_HOST="127.0.0.1"
TERMINUS_DB_PORT="5432"
TERMINUS_DB_NAME="terminus"
TERMINUS_DB_USER="terminus"
TERMINUS_DB_PASSWORD="terminus"

TERMINUS_KEYVALUE_HOST="127.0.0.1"
TERMINUS_KEYVALUE_PORT="6379"
TERMINUS_KEYVALUE_PASSWORD="terminus"

PUMA_WORKERS="${PUMA_WORKERS:-1}"
PUMA_MIN_THREADS="${PUMA_MIN_THREADS:-1}"
PUMA_MAX_THREADS="${PUMA_MAX_THREADS:-2}"
SIDEKIQ_CONCURRENCY="${SIDEKIQ_CONCURRENCY:-1}"

POSTGRES_MAX_CONNECTIONS="${POSTGRES_MAX_CONNECTIONS:-10}"
POSTGRES_SHARED_BUFFERS="${POSTGRES_SHARED_BUFFERS:-64MB}"
POSTGRES_WORK_MEM="${POSTGRES_WORK_MEM:-1MB}"
POSTGRES_MAINTENANCE_WORK_MEM="${POSTGRES_MAINTENANCE_WORK_MEM:-16MB}"
POSTGRES_EFFECTIVE_CACHE_SIZE="${POSTGRES_EFFECTIVE_CACHE_SIZE:-128MB}"
POSTGRES_MAX_WORKER_PROCESSES="${POSTGRES_MAX_WORKER_PROCESSES:-2}"
POSTGRES_MAX_PARALLEL_WORKERS="${POSTGRES_MAX_PARALLEL_WORKERS:-0}"
POSTGRES_MAX_PARALLEL_WORKERS_PER_GATHER="${POSTGRES_MAX_PARALLEL_WORKERS_PER_GATHER:-0}"

REDIS_MAXMEMORY="${REDIS_MAXMEMORY:-64mb}"
REDIS_MAXMEMORY_POLICY="${REDIS_MAXMEMORY_POLICY:-allkeys-lru}"
REDIS_SAVE_SECONDS="${REDIS_SAVE_SECONDS:-1800}"
REDIS_SAVE_CHANGES="${REDIS_SAVE_CHANGES:-1}"

POSTGRES_PID=""
REDIS_PID=""
PUMA_PID=""
SIDEKIQ_PID=""
SHUTDOWN_IN_PROGRESS="false"

if [[ ! -f "${SETUP_HELPER_FILE}" ]]; then
    echo "Unable to find setup helper script at ${SETUP_HELPER_FILE}."
    exit 1
fi

# shellcheck source=/opt/addon/lib/setup.sh
source "${SETUP_HELPER_FILE}"

read_required_option() {
    local key="$1"

    jq -er --arg key "${key}" '.[$key] | select(type == "string" and length > 0)' "${OPTIONS_FILE}"
}

read_or_generate_secret() {
    local secret_file="$1"
    local secret_bytes="$2"
    local secret_value=""

    if [[ -s "${secret_file}" ]]; then
        secret_value="$(tr -d '\r\n' < "${secret_file}")"
    else
        secret_value="$(ruby -e 'require "securerandom"; print SecureRandom.hex(ARGV[0].to_i)' "${secret_bytes}")"
        (umask 077 && printf '%s' "${secret_value}" > "${secret_file}")
    fi

    if [[ -z "${secret_value}" ]]; then
        echo "Secret file ${secret_file} is empty."
        return 1
    fi

    chmod 600 "${secret_file}" 2>/dev/null || true
    printf '%s' "${secret_value}"
}

run_as_user() {
    local user="$1"
    shift

    if [[ "$(id -u)" -eq 0 ]]; then
        s6-setuidgid "${user}" "$@"
    else
        "$@"
    fi
}

ensure_ownership_if_needed() {
    local path="$1"
    local target_user="$2"
    local target_group="$3"
    local target_uid=""
    local target_gid=""
    local current_owner=""

    if [[ "$(id -u)" -ne 0 ]] || [[ ! -e "${path}" ]]; then
        return 0
    fi

    target_uid="$(id -u "${target_user}")"
    target_gid="$(id -g "${target_group}")"
    current_owner="$(stat -c '%u:%g' "${path}" 2>/dev/null || true)"

    if [[ "${current_owner}" != "${target_uid}:${target_gid}" ]]; then
        chown -R "${target_user}:${target_group}" "${path}"
    fi
}

run_as_app() {
    local command="$1"

    if id app >/dev/null 2>&1; then
        run_as_user app /bin/bash -lc "${command}"
    else
        sh -c "${command}"
    fi
}

run_as_postgres() {
    local command="$1"

    if id postgres >/dev/null 2>&1; then
        run_as_user postgres /bin/sh -lc "${command}"
    else
        sh -c "${command}"
    fi
}

wait_for_postgres() {
    local retries=30

    until pg_isready -h "${TERMINUS_DB_HOST}" -p "${TERMINUS_DB_PORT}" >/dev/null 2>&1; do
        retries=$((retries - 1))
        if [[ "${retries}" -le 0 ]]; then
            echo "PostgreSQL failed to start in time."
            return 1
        fi
        sleep 1
    done
}

wait_for_redis() {
    local retries=30

    until REDISCLI_AUTH="${TERMINUS_KEYVALUE_PASSWORD}" redis-cli -h "${TERMINUS_KEYVALUE_HOST}" -p "${TERMINUS_KEYVALUE_PORT}" ping >/dev/null 2>&1; do
        retries=$((retries - 1))
        if [[ "${retries}" -le 0 ]]; then
            echo "Redis failed to start in time."
            return 1
        fi
        sleep 1
    done
}

run_setup_step() {
    local step_name="$1"
    local command="$2"
    local step_slug=""
    local log_file=""

    step_slug="${step_name// /_}"
    log_file="/tmp/terminus-setup-${step_slug}-$RANDOM.log"
    echo "Running setup step: ${step_name}"

    if ! run_as_app "${command}" >"${log_file}" 2>&1; then
        echo "Setup step failed: ${step_name}"
        echo "Showing last 200 lines from ${log_file}:"
        tail -n 200 "${log_file}" || true
        rm -f "${log_file}"
        return 1
    fi

    rm -f "${log_file}"
}

bootstrap_postgres() {
    mkdir -p "${POSTGRES_DATA_DIR}" "${POSTGRES_RUNTIME_DIR}"

    if id postgres >/dev/null 2>&1; then
        ensure_ownership_if_needed /config/postgres postgres postgres
        ensure_ownership_if_needed "${POSTGRES_RUNTIME_DIR}" postgres postgres
    fi

    if [[ ! -s "${POSTGRES_DATA_DIR}/PG_VERSION" ]]; then
        echo "Initializing bundled PostgreSQL data directory..."
        run_as_postgres "initdb -D '${POSTGRES_DATA_DIR}' --username=postgres --auth-local=peer --auth-host=scram-sha-256"
    fi

    if [[ -f "${POSTGRES_DATA_DIR}/pg_hba.conf" ]]; then
        sed -i \
            -e 's/^local[[:space:]]\+all[[:space:]]\+all[[:space:]]\+trust$/local all all peer/' \
            -e 's#^host[[:space:]]\+all[[:space:]]\+all[[:space:]]\+127\.0\.0\.1/32[[:space:]]\+trust$#host all all 127.0.0.1/32 scram-sha-256#' \
            -e 's#^host[[:space:]]\+all[[:space:]]\+all[[:space:]]\+::1/128[[:space:]]\+trust$#host all all ::1/128 scram-sha-256#' \
            "${POSTGRES_DATA_DIR}/pg_hba.conf"
    fi

    echo "Starting bundled PostgreSQL..."
    run_as_postgres "postgres -D '${POSTGRES_DATA_DIR}' -h '${TERMINUS_DB_HOST}' -p '${TERMINUS_DB_PORT}' \
        -c max_connections='${POSTGRES_MAX_CONNECTIONS}' \
        -c shared_buffers='${POSTGRES_SHARED_BUFFERS}' \
        -c work_mem='${POSTGRES_WORK_MEM}' \
        -c maintenance_work_mem='${POSTGRES_MAINTENANCE_WORK_MEM}' \
        -c effective_cache_size='${POSTGRES_EFFECTIVE_CACHE_SIZE}' \
        -c max_worker_processes='${POSTGRES_MAX_WORKER_PROCESSES}' \
        -c max_parallel_workers='${POSTGRES_MAX_PARALLEL_WORKERS}' \
        -c max_parallel_workers_per_gather='${POSTGRES_MAX_PARALLEL_WORKERS_PER_GATHER}'" &
    POSTGRES_PID=$!

    wait_for_postgres

    run_as_postgres "psql -v ON_ERROR_STOP=1 --username=postgres --dbname=postgres \
        -v terminus_db_user='${TERMINUS_DB_USER}' \
        -v terminus_db_password='${TERMINUS_DB_PASSWORD}' \
        -v terminus_db_name='${TERMINUS_DB_NAME}' \
        -f '${POSTGRES_BOOTSTRAP_SQL_FILE}'"
}

bootstrap_redis() {
    local redis_user=""
    local redis_group=""

    mkdir -p "${REDIS_DATA_DIR}"

    if id redis >/dev/null 2>&1; then
        redis_user="redis"
    elif id app >/dev/null 2>&1; then
        redis_user="app"
    fi

    if [[ -n "${redis_user}" ]] && [[ "$(id -u)" -eq 0 ]]; then
        redis_group="$(id -gn "${redis_user}")"
        ensure_ownership_if_needed "${REDIS_DATA_DIR}" "${redis_user}" "${redis_group}"
    fi

    echo "Starting bundled Redis..."
    if [[ -n "${redis_user}" ]]; then
        run_as_user "${redis_user}" redis-server \
            --bind "${TERMINUS_KEYVALUE_HOST}" \
            --port "${TERMINUS_KEYVALUE_PORT}" \
            --dir "${REDIS_DATA_DIR}" \
            --appendonly yes \
            --appendfsync everysec \
            --save "${REDIS_SAVE_SECONDS}" "${REDIS_SAVE_CHANGES}" \
            --maxmemory "${REDIS_MAXMEMORY}" \
            --maxmemory-policy "${REDIS_MAXMEMORY_POLICY}" \
            --requirepass "${TERMINUS_KEYVALUE_PASSWORD}" &
    else
        redis-server \
            --bind "${TERMINUS_KEYVALUE_HOST}" \
            --port "${TERMINUS_KEYVALUE_PORT}" \
            --dir "${REDIS_DATA_DIR}" \
            --appendonly yes \
            --appendfsync everysec \
            --save "${REDIS_SAVE_SECONDS}" "${REDIS_SAVE_CHANGES}" \
            --maxmemory "${REDIS_MAXMEMORY}" \
            --maxmemory-policy "${REDIS_MAXMEMORY_POLICY}" \
            --requirepass "${TERMINUS_KEYVALUE_PASSWORD}" &
    fi
    REDIS_PID=$!

    wait_for_redis
}

start_terminus_services() {
    run_as_app "bundle exec puma --config ./config/puma.rb --workers ${PUMA_WORKERS} --threads ${PUMA_MIN_THREADS}:${PUMA_MAX_THREADS}" &
    PUMA_PID=$!
    run_as_app "bundle exec sidekiq -r ./config/sidekiq.rb -c ${SIDEKIQ_CONCURRENCY}" &
    SIDEKIQ_PID=$!
}

shutdown_all() {
    if [[ "${SHUTDOWN_IN_PROGRESS}" == "true" ]]; then
        return
    fi
    SHUTDOWN_IN_PROGRESS="true"

    set +e

    if [[ -n "${PUMA_PID}" ]] && kill -0 "${PUMA_PID}" 2>/dev/null; then
        kill "${PUMA_PID}" 2>/dev/null
    fi
    if [[ -n "${SIDEKIQ_PID}" ]] && kill -0 "${SIDEKIQ_PID}" 2>/dev/null; then
        kill "${SIDEKIQ_PID}" 2>/dev/null
    fi

    if [[ -n "${REDIS_PID}" ]] && kill -0 "${REDIS_PID}" 2>/dev/null; then
        kill "${REDIS_PID}" 2>/dev/null
    fi

    if [[ -n "${POSTGRES_PID}" ]] && kill -0 "${POSTGRES_PID}" 2>/dev/null; then
        run_as_postgres "pg_ctl -D '${POSTGRES_DATA_DIR}' -m fast stop" >/dev/null 2>&1 || kill "${POSTGRES_PID}" 2>/dev/null
    fi
}

on_signal() {
    shutdown_all
    exit 0
}

if [[ ! -f "${OPTIONS_FILE}" ]]; then
    echo "Unable to find add-on options file at ${OPTIONS_FILE}."
    exit 1
fi

if [[ ! -d /app ]]; then
    echo "Unable to find Terminus app directory at /app."
    exit 1
fi

cd /app

export BUNDLE_GEMFILE="/app/Gemfile"
export BUNDLE_DEPLOYMENT="1"
export BUNDLE_PATH="/usr/local/bundle"
export BUNDLE_WITHOUT="development:quality:test:tools"
export GEM_HOME="/usr/local/bundle"
export GEM_PATH="/usr/local/bundle"
export PATH="/usr/local/bundle/ruby/4.0.0/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
export RACK_ENV="production"
export HANAMI_ENV="production"
export HANAMI_SERVE_ASSETS="true"

API_URI="$(read_required_option "api_uri")"
APP_SETUP="$(jq -er '.app_setup // true' "${OPTIONS_FILE}")"
CERTIFICATE_URLS="$(jq -er '.certificate_urls // empty' "${OPTIONS_FILE}")"
APP_SECRET="$(jq -er '.app_secret // empty' "${OPTIONS_FILE}")"

if [[ -z "${APP_SECRET}" ]]; then
    if [[ -s /config/.app_secret ]]; then
        APP_SECRET="$(cat /config/.app_secret)"
    else
        APP_SECRET="$(ruby -e 'require "securerandom"; print SecureRandom.hex(64)')"
        (umask 077 && printf '%s' "${APP_SECRET}" > /config/.app_secret)
    fi
fi

chmod 600 /config/.app_secret 2>/dev/null || true

TERMINUS_DB_PASSWORD="$(read_or_generate_secret "${TERMINUS_DB_PASSWORD_FILE}" "32")"
TERMINUS_KEYVALUE_PASSWORD="$(read_or_generate_secret "${TERMINUS_KEYVALUE_PASSWORD_FILE}" "32")"

mkdir -p /config/uploads

if [[ -d /app/public/uploads && ! -L /app/public/uploads ]]; then
    cp -an /app/public/uploads/. /config/uploads/ 2>/dev/null || true
    rm -rf /app/public/uploads
fi

if [[ ! -L /app/public/uploads ]]; then
    ln -s /config/uploads /app/public/uploads
fi

if id app >/dev/null 2>&1; then
    ensure_ownership_if_needed /config/uploads app app
fi

bootstrap_postgres
bootstrap_redis

export API_URI
export APP_SECRET
export CERTIFICATE_URLS
export HANAMI_PORT="2300"
export DATABASE_URL="postgres://${TERMINUS_DB_USER}:${TERMINUS_DB_PASSWORD}@${TERMINUS_DB_HOST}:${TERMINUS_DB_PORT}/${TERMINUS_DB_NAME}"
export KEYVALUE_URL="redis://:${TERMINUS_KEYVALUE_PASSWORD}@${TERMINUS_KEYVALUE_HOST}:${TERMINUS_KEYVALUE_PORT}/0"

if [[ -n "${CERTIFICATE_URLS}" ]]; then
    scripts/docker/install-certificates
fi

run_setup_if_needed "${APP_SETUP}" "${SETUP_MARKER_FILE}" "${MIGRATION_MARKER_FILE}"

echo "Starting Terminus web server and Sidekiq worker..."
trap on_signal SIGINT SIGTERM

start_terminus_services

wait -n "${POSTGRES_PID}" "${REDIS_PID}" "${PUMA_PID}" "${SIDEKIQ_PID}"
EXIT_CODE=$?

echo "One of the bundled services exited. Shutting down the add-on..."
shutdown_all
wait || true
exit "${EXIT_CODE}"
