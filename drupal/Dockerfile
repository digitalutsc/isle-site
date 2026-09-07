# syntax=docker/dockerfile:1.26.0@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
ARG REPOSITORY
ARG TAG
FROM ${REPOSITORY}/drupal:${TAG}

ARG TARGETARCH

# Islandora Lite media tooling. Must precede composer install: drupal/media_thumbnails_pdf
# requires ext-imagick, so composer's platform check fails without it. The pecl package name is
# PHP-version-suffixed and the version moves with the image line, so derive it. See LITE.md.
# hadolint ignore=DL3018
RUN apk add --no-cache imagemagick ffmpeg \
      "php$(php -r 'echo PHP_MAJOR_VERSION . PHP_MINOR_VERSION;')-pecl-imagick"

COPY --link rootfs /

RUN --mount=type=cache,id=custom-drupal-composer-${TARGETARCH},sharing=locked,target=/root/.composer/cache \
    composer install -d /var/www/drupal && \
    chown -R nginx:nginx /var/www/drupal && \
    cleanup.sh
