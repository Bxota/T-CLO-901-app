# Utilisez une image Docker officielle pour PHP 7.4 avec Apache
FROM php:8.2.8-apache

# Installez les extensions PHP nécessaires
RUN docker-php-ext-install pdo_mysql

# APCu backs the Prometheus metrics registry: it is shared by every Apache
# worker of a pod and survives between requests (in-memory storage would not).
RUN pecl install apcu-5.1.24 \
    && docker-php-ext-enable apcu \
    && echo "apc.enable_cli=0" > /usr/local/etc/php/conf.d/zz-apcu.ini

RUN apt-get update && apt-get install -y git unzip p7zip-full

# Installez Composer
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Copiez les fichiers de l'application dans le conteneur
COPY . /var/www/html/

# Laravel utilise ce répertoire pendant l'installation de Composer
# (le script post-autoload-dump lance `artisan package:discover`).
RUN mkdir -p \
    /var/www/html/bootstrap/cache \
    /var/www/html/storage/framework/cache \
    /var/www/html/storage/framework/data \
    /var/www/html/storage/framework/sessions \
    /var/www/html/storage/framework/views \
    /var/www/html/storage/logs

# Installez les dépendances de l'application
RUN composer install

RUN chown -R www-data:www-data /var/www/html/vendor /var/www/html/storage /var/www/html/bootstrap /var/www/html/public /var/www/html/app /var/www/html/config /var/www/html/routes /var/www/html/resources
RUN chmod -R 755 /var/www/html/vendor /var/www/html/storage /var/www/html/bootstrap /var/www/html/public /var/www/html/app /var/www/html/config /var/www/html/routes /var/www/html/resources

# Modifiez la configuration d'Apache pour pointer vers le répertoire public
ENV APACHE_DOCUMENT_ROOT /var/www/html/public
RUN sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf
RUN sed -ri -e 's!/var/www/!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf

# Activez le module Apache Rewrite
RUN a2enmod rewrite

# Exposez le port 80
EXPOSE 80
