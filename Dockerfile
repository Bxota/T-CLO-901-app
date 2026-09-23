# syntax=docker/dockerfile:1
# Two stages on the same PHP base so `artisan package:discover` runs under the
# runtime PHP version. The final image carries no Composer, no git/unzip, and
# no dev dependencies.
# Rolling 8.2 patch tag: the pinned 8.2.8 (mid-2023 Debian) carried ~1900
# HIGH/CRITICAL OS CVEs; the current 8.2.x carries ~160, none fixable in Debian.
ARG PHP_IMAGE=php:8.2-apache

FROM ${PHP_IMAGE} AS vendor
WORKDIR /var/www/html
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
# unzip is needed by Composer only; this stage is discarded.
RUN apt-get update && apt-get install -y --no-install-recommends unzip && rm -rf /var/lib/apt/lists/*
# Dependencies first, so this layer is cached until composer.lock changes.
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-interaction --prefer-dist --no-progress --no-scripts --no-autoloader
COPY . .
RUN mkdir -p bootstrap/cache storage/framework/cache/data storage/framework/sessions storage/framework/views storage/logs \
    && composer dump-autoload --no-dev --optimize --classmap-authoritative \
    && php artisan package:discover --ansi

FROM ${PHP_IMAGE}
# pdo_mysql for the database; APCu backs the Prometheus metrics registry (shared
# by every Apache worker of a pod, survives between requests). Build artefacts
# are removed in the same layer.
RUN docker-php-ext-install -j"$(nproc)" pdo_mysql \
    && pecl install apcu-5.1.24 \
    && docker-php-ext-enable apcu \
    && echo "apc.enable_cli=0" > /usr/local/etc/php/conf.d/zz-apcu.ini \
    && rm -rf /tmp/pear ~/.pearrc \
    && mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

ENV APACHE_DOCUMENT_ROOT=/var/www/html/public
RUN sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf \
    && sed -ri -e 's!/var/www/!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf \
    && a2enmod rewrite

WORKDIR /var/www/html
COPY --from=vendor --chown=www-data:www-data /var/www/html /var/www/html

EXPOSE 80
