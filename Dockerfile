FROM ruby:4.0-alpine

RUN apk add --no-cache git bash build-base

COPY Gemfile /action/Gemfile
COPY Gemfile.lock /action/Gemfile.lock
COPY vendor/cache /action/vendor/cache
WORKDIR /action
RUN bundle config set --local path vendor/bundle && \
    bundle config set --local without test && \
    bundle install --local --jobs 4

ENV BUNDLE_GEMFILE=/action/Gemfile \
    BUNDLE_PATH=/action/vendor/bundle \
    BUNDLE_WITHOUT=test

COPY scripts/ /action/scripts/
COPY entrypoint.sh /action/entrypoint.sh
RUN chmod +x /action/entrypoint.sh

ENTRYPOINT ["/action/entrypoint.sh"]
