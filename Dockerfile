FROM ghcr.io/home-assistant/base:latest

ENV LANG=C.UTF-8 \
    RACK_ENV=production \
    HANAMI_ENV=production \
    HANAMI_SERVE_ASSETS=true \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:quality:test:tools

WORKDIR /app

RUN apk add --no-cache \
        bash \
        ca-certificates \
        chromium \
        curl \
        font-noto-cjk \
        git \
        imagemagick \
        jq \
        nodejs \
        npm \
        postgresql-client \
        postgresql-libs \
        ruby \
        ruby-bundler \
        tmux \
        tzdata \
    && apk add --no-cache --virtual .build-deps \
        build-base \
        linux-headers \
        pkgconf \
        postgresql-dev \
        ruby-dev \
        yaml-dev \
    && gem update --system --no-document \
    && gem install --no-document bundler \
    && git clone --depth 1 --single-branch https://github.com/usetrmnl/terminus /app \
    && npm ci \
    && bundle config set deployment true \
    && bundle config set without "development quality test tools" \
    && bundle install --jobs 4 --retry 3 \
    && rm -rf /root/.cache /tmp/* \
    && apk del .build-deps

RUN addgroup -S app \
    && adduser -S -G app -h /app app \
    && chown -R app:app /app /usr/local/bundle

COPY run.sh /run.sh
RUN chmod a+x /run.sh

EXPOSE 2300/tcp

CMD ["/run.sh"]
