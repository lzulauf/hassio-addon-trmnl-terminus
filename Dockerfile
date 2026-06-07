FROM ghcr.io/home-assistant/base:latest AS ruby-builder

ARG RUBY_VERSION=4.0.5

# If Home Assistant base ever ships Ruby >= 4.0.5, this stage can be removed.
# Quick check command:
#   docker run --rm --entrypoint /bin/sh ghcr.io/home-assistant/base:latest -lc "apk update >/dev/null; apk policy ruby"
# If the reported ruby package is >= 4.0.5, use apk-provided Ruby in builder/final
# and drop all source-build dependencies below.

RUN apk add --no-cache \
        autoconf \
        bison \
        build-base \
        ca-certificates \
        curl \
        libffi-dev \
        linux-headers \
        openssl-dev \
        readline-dev \
        yaml-dev \
        zlib-dev

WORKDIR /tmp/ruby-src

RUN curl -fsSL "https://cache.ruby-lang.org/pub/ruby/${RUBY_VERSION%.*}/ruby-${RUBY_VERSION}.tar.xz" -o ruby.tar.xz
RUN tar -xJf ruby.tar.xz --strip-components=1
RUN ./configure --disable-install-doc --enable-shared
RUN make -j"$(nproc)"
RUN make install
RUN gem update --system --no-document
RUN gem install --no-document bundler -v 2.6.9
RUN ruby -v
RUN bundle --version

FROM ghcr.io/home-assistant/base:latest AS app-builder

ARG TERMINUS_REF=main

ENV LANG=C.UTF-8 \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:quality:test:tools

RUN apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        git \
        libffi-dev \
        linux-headers \
        nodejs \
        npm \
        openssl-dev \
        pkgconf \
        postgresql-dev \
        readline-dev \
        yaml-dev \
        zlib-dev \
        build-base

COPY --from=ruby-builder /usr/local /usr/local

WORKDIR /app

RUN curl -fsSL "https://github.com/usetrmnl/terminus/archive/${TERMINUS_REF}.tar.gz" -o /tmp/terminus.tar.gz \
    && tar -xzf /tmp/terminus.tar.gz -C /app --strip-components=1 \
    && printf '%s' "${TERMINUS_REF}" > /app/.terminus_ref \
    && rm -f /tmp/terminus.tar.gz
RUN npm ci --no-audit --no-fund
RUN bundle config set deployment true
RUN bundle config set without "development quality test tools"
RUN bundle install --jobs "$(nproc)" --retry 3
RUN bundle exec hanami assets compile

FROM ghcr.io/home-assistant/base:latest

ARG RUBY_VERSION=4.0.5

ENV LANG=C.UTF-8 \
    RACK_ENV=production \
    HANAMI_ENV=production \
    HANAMI_SERVE_ASSETS=true \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:quality:test:tools

RUN apk add --no-cache \
        bash \
        ca-certificates \
        chromium \
        curl \
        font-noto-cjk \
        git \
        imagemagick \
        jq \
        libffi \
        libgcc \
        libstdc++ \
        openssl \
        postgresql \
        postgresql-client \
        postgresql-contrib \
        readline \
        redis \
        tzdata \
        yaml \
        zlib

COPY --from=ruby-builder /usr/local /usr/local
COPY --from=app-builder /app /app
COPY --from=app-builder /usr/local/bundle /usr/local/bundle

RUN rm -rf /usr/local/bundle/cache /usr/local/include \
    && find /usr/local -type f -name '*.a' -delete \
    && if [ -d /usr/local/bundle ]; then find /usr/local/bundle -type f \( -name '*.c' -o -name '*.o' \) -delete; fi

WORKDIR /app

RUN ruby -v

RUN addgroup -S app \
    && adduser -S -G app -h /app app \
    && chown -R app:app /app /usr/local/bundle

COPY run.sh /run.sh
COPY lib /opt/addon/lib
COPY sql /opt/addon/sql
RUN chmod a+x /run.sh

EXPOSE 2300/tcp

CMD ["/run.sh"]
