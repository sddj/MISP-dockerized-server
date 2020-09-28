#FROM debian:stretch-slim
FROM ubuntu:20.04
ENV DEBIAN_FRONTEND noninteractive
ENV DEBIAN_PRIORITY critical

# Base dependencies
RUN apt-get update && apt-get install -y \
build-essential \
locales \
iputils-ping \
net-tools \
supervisor \
gosu \
wget \
rsyslog \
sudo \
nano \
&& apt-get autoremove -y && apt-get clean -y

# Set locals
ARG LANG=en_US.UTF-8
RUN locale-gen ${LANG}

#########################    START  MISP Guide

# Install additional SSL certificates
RUN mkdir -p /usr/local/share/ca-certificates/extra
COPY ca-certs/* /usr/local/share/ca-certificates/extra/
RUN /usr/sbin/update-ca-certificates

# 1/ Minimal Ubuntu install 
# based on: https://raw.githubusercontent.com/MISP/MISP/2.4/INSTALL/INSTALL.sh
# -------------------------

#RUN wget -O /tmp/INSTALL.sh https://raw.githubusercontent.com/MISP/MISP/2.4/INSTALL/INSTALL.sh; \
#    bash /tmp/INSTALL.sh
##### Avoid tzdata dialog during install
RUN DEBIAN_FRONTEND="noninteractive" apt-get -y install tzdata

##### Install core dependencies

RUN apt update && apt install -qy \
    apt-utils curl gcc git gnupg-agent make openssl redis-server neovim unzip zip libyara-dev sqlite3 \
    mariadb-client mariadb-server \
    apache2 apache2-doc apache2-utils \
    libpq5 libjpeg-dev libfuzzy-dev ruby asciidoctor \
    libxml2-dev libxslt1-dev zlib1g-dev expect \
    python3-dev python3-pip python3 python3-yara python3-redis python3-zmq python3-setuptools && \
    apt-get clean -y

##### Configure Database
# add own mysql config
#COPY files/etc/mysql/mariadb.conf.d/DCSO.cnf /etc/mysql/mariadb.conf.d/

##### Install PHP 7.4 dependencies
RUN apt update && \
    apt install -qy \
    libapache2-mod-php \
    php php-cli \
    php-dev \
    php-json php-xml php-mysql php-opcache php-readline php-mbstring \
    php-redis php-gnupg \
    php-gd php-zip php-intl && \
    apt clean -y

##### Install MISP Core
ARG VERSION=""
ARG MISP_ARG=${VERSION}
ENV MISP_TAG="${MISP_ARG}"
ENV WWW_USER="www-data"
ENV PATH_TO_MISP="/var/www/MISP"
ENV SUDO_WWW="sudo -H -u ${WWW_USER}"

RUN set -eu; \
    git clone https://github.com/MISP/MISP.git ${PATH_TO_MISP}; \
    cd ${PATH_TO_MISP}; \
    git checkout tags/v${VERSION:-2.4.125}; \
    chown -R ${WWW_USER}:${WWW_USER} ${PATH_TO_MISP}; \
    cd ${PATH_TO_MISP}; \
    ${SUDO_WWW} git config core.filemode false; \
    ${SUDO_WWW} git submodule sync; \
    ${SUDO_WWW} git submodule update --init --recursive; \
    ${SUDO_WWW} git submodule foreach --recursive git config core.filemode false; \
    chown -R ${WWW_USER}:${WWW_USER} ${PATH_TO_MISP}; \
    cd cti-python-stix2; \
    pip3 install -I .;

RUN pip3 install wheel mixbox cybox stix maec stix2 antlr4-python3-runtime git+https://github.com/kbandla/pydeep.git zmq redis python-magic plyara && \
    pip3 install --index-url  https://lief-project.github.io/packages lief && \
    pip3 install git+https://github.com/MISP/PyMISP

# ssdeep
RUN set -eu; \
    cd /usr/local/src; \
    rm -rf ssdeep-*; \
    wget https://github.com/ssdeep-project/ssdeep/releases/download/release-2.14.1/ssdeep-2.14.1.tar.gz; \
    tar zxf ssdeep-2.14.1.tar.gz; \
    cd ssdeep-2.14.1; \
    ./configure --datadir=/usr --prefix=/usr --localstatedir=/var --sysconfdir=/etc; \
    make; \
    make install; \
    pecl channel-update pecl.php.net; \
    pecl install ssdeep; \
    for P in /etc/php/*; do (echo "extension=ssdeep.so" | tee "${P}/mods-available/ssdeep.ini"); done; \
    phpenmod ssdeep; \
    cd ..; \
    rm -rf ssdeep-*

##### Install CakePHP
# Once done, install CakeResque along with its dependencies 
# if you intend to use the built in background jobs:
RUN set -eu; \
    cd ${PATH_TO_MISP}/app; \
    mkdir /var/www/.composer ; \
    chown $WWW_USER:$WWW_USER /var/www/.composer; \
    $SUDO_WWW php composer.phar install;

# Enable CakeResque with php-redis
RUN phpenmod redis; \
    phpenmod gnupg;

# To use the scheduler worker for scheduled tasks, do the following:
RUN $SUDO_WWW cp -fa ${PATH_TO_MISP}/INSTALL/setup/config.php ${PATH_TO_MISP}/app/Plugin/CakeResque/Config/config.php

##### Set permissions
RUN chown -R ${WWW_USER}:${WWW_USER} ${PATH_TO_MISP}; \
    chmod -R 750 ${PATH_TO_MISP}; \
    chmod -R g+ws ${PATH_TO_MISP}/app/tmp; \
    chmod -R g+ws ${PATH_TO_MISP}/app/files; \
    chmod -R g+ws $PATH_TO_MISP/app/files/scripts/tmp


##### Configure Apache
# add HTTP MISP Config
RUN rm /etc/apache2/sites-enabled/*;
COPY files/etc/apache2/sites-enabled/misp.ssl /etc/apache2/sites-enabled/
COPY files/etc/apache2/sites-enabled/misp.conf /etc/apache2/sites-enabled/
COPY files/etc/apache2/ports.conf /etc/apache2/ports.conf
RUN set -eu \
    chmod 640 /etc/apache2/ports.conf; \
    chown root.root /etc/apache2/ports.conf; \
    chmod 640 /etc/apache2/sites-available/*; \
    chown root.root /etc/apache2/sites-available/*; \
    a2dismod status; \
    a2enmod ssl; \
    a2enmod rewrite; \
    a2enmod headers

##### Enable Log rotation
# MISP saves the stdout and stderr of its workers in /var/www/MISP/app/tmp/logs
# To rotate these logs install the supplied logrotate script:
RUN cp /var/www/MISP/INSTALL/misp.logrotate /etc/logrotate.d/misp

##### Prepare mail encryption
RUN set -eu; \
    $SUDO_WWW mkdir /var/www/MISP/.smime; \
    $SUDO_WWW chmod 500 /var/www/MISP/.smime; \
    $SUDO_WWW mkdir /var/www/MISP/.gnupg; \
    $SUDO_WWW chmod 700 /var/www/MISP/.gnupg; \
    touch "/var/www/MISP/app/Config/NOT_CONFIGURED";

##### Copy "Mode for Ralf" patch File for MISP Events Page with additional Analyse Column
COPY --chown=www-data:www-data files/var/www/MISP/app/View/Elements/Events/eventIndexTable.patch /

##### Setting up background workers
COPY files/etc/rc.local /etc/
COPY files/etc/systemd/system/misp-workers.service /etc/systemd/system/
RUN chmod +x $PATH_TO_MISP/app/Console/worker/start.sh; \
    chmod 744 /etc/rc.local
    #sudo systemctl daemon-reload; \
    #sudo systemctl enable --now misp-workers

##### Install and configure postfix
# Copy files to postfix container
RUN apt install -qy postfix
COPY files/etc/postfix/* /etc/postfix/
RUN chown -R postfix:postfix /etc/postfix/*

##### Copy additional scripts
# MISP Update and MISP Cron
COPY --chown=www-data:www-data files/usr/local/bin/misp_update.sh /usr/local/bin/
COPY --chown=www-data:www-data files/usr/local/bin/misp_cron.sh /usr/local/bin/

##### Finish image
# Healthcheck
COPY files/healthcheck.sh /
HEALTHCHECK --interval=1m --timeout=45s --retries=3 CMD ["/healthcheck.sh"]

# Patches
COPY files/patches.d /patches.d

# Entrypoints
COPY files/entrypoint_apache.sh /
COPY files/entrypoint_cron.sh /
COPY files/entrypoint_mariadb.sh /
COPY files/entrypoint_mariadb2.sh /
COPY files/entrypoint_postfix.sh /
COPY files/entrypoint_redis.sh /
COPY files/entrypoint_rsyslog.sh /
COPY files/entrypoint_workers.sh /
COPY files/entrypoint.sh /
ENTRYPOINT [ "/entrypoint.sh" ]

# Change Workdirectory
WORKDIR /var/www/MISP

# Variables for labels:
ARG VENDOR="DCSO GmbH"
ARG COMPONENT="server"
ARG BUILD_DATE
ARG GIT_REPO
ARG VCS_REF
ARG VERSION
ARG RELEASE_DATE
ARG NAME="MISP-dockerized-${COMPONENT}"
ARG DESCRIPTION="This docker container is part of the DCSO MISP dockerized environment."
ARG DOCUMENTATION="https://github.com/DCSO/MISP-dockerized"
ARG AUTHOR="DCSO MISP Docker Team <misp.docker@dcso.de>"
ARG LICENSE="BSD-3-Clause"

##### Set environment variables
ENV CMD_MYSQL=mysqld \
CMD_APACHE=none \
CMD_REDIS="--appendonly yes" \
NAME=${NAME} \
VERSION=${VERSION} \
RELEASE_DATE=${RELEASE_DATE} \
http_proxy="" \
https_proxy="" \
no_proxy="0.0.0.0" \
MYSQL_HOST="localhost" \
MYSQL_DATABASE="misp" \
MYSQL_USER="misp" \
MYSQL_PASSWORD="ChangeMe123!" \
HOSTNAME=misp \
DOMAIN=example.com \
SENDER_ADDRESS=admin@example.com \
RELAYHOST=smtp.example.local:587 \
RELAY_USER=misp \
RELAY_PASSWORD=ChangeMe \
DOCKER_NETWORK=192.168.47.0/28 \
DEBUG_PEER=none \
LANGUAGE=en_US:en


# Labels
LABEL org.label-schema.build-date="${BUILD_DATE}" \
        org.label-schema.name="${NAME}" \
        org.label-schema.description="${DESCRIPTION}" \
        org.label-schema.vcs-ref="${VCS_REF}" \
        org.label-schema.vcs-url="${GIT_REPO}" \
        org.label-schema.url="${GIT_REPO}" \
        org.label-schema.vendor="${VENDOR}" \
        org.label-schema.version="${VERSION}" \
        org.label-schema.usage="${DOCUMENTATION}" \
        org.label-schema.schema-version="1.0.0-rc1"

LABEL   org.opencontainers.image.created="${BUILD_DATE}" \
        org.opencontainers.image.url="${GIT_REPO}" \
        org.opencontainers.image.source="${GIT_REPO}" \
        org.opencontainers.image.version="${VERSION}" \
        org.opencontainers.image.revision="${VCS_REF}" \
        org.opencontainers.image.vendor="${VENDOR}" \
        org.opencontainers.image.title="${NAME}" \
        org.opencontainers.image.description="${DESCRIPTION}" \
        org.opencontainers.image.documentation="${DOCUMENTATION}" \
        org.opencontainers.image.authors="${AUTHOR}" \
        org.opencontainers.image.licenses="${LICENSE}"

#       End of DCSO MISP Config Part
#########################################
