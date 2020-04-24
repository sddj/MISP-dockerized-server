#!/bin/bash
set -e
DEBIAN_FRONTEND=noninteractive

NC='\033[0m' # No Color
Light_Green='\033[1;32m'  
echo (){
    command echo -e "$@"
}

STARTMSG="${Light_Green}[ENTRYPOINT_APACHE]${NC}"
ENTRYPOINT_PID_FILE="/entrypoint_apache.install"
[ ! -f $ENTRYPOINT_PID_FILE ] && touch $ENTRYPOINT_PID_FILE

# --help, --version
[ "$1" = "--help" ] || [ "$1" = "--version" ] && exec start_apache "$1"
# treat everything except -- as exec cmd
[ "${1:0:2}" != "--" ] && exec "$@"

if [ -z "${MISP_MODULES_URL}" ]; then
    MISP_MODULES_URL="http://misp-modules"
    MISP_MODULES_PORT="6666"
else
    # http://$host:$port => MISP_MODULES_URL=http://$host, MISP_MODULES_PORT=$port
    # http://$host => MISP_MODULES_URL=http://$host, MISP_MODULES_PORT=80
    # https://$host:$port => MISP_MODULES_URL=https://$host, MISP_MODULES_PORT=$port
    # https://$host => MISP_MODULES_URL=https://$host, MISP_MODULES_PORT=443
    # $host:$port => MISP_MODULES_URL=http://$host, MISP_MODULES_PORT=$port
    # $host => MISP_MODULES_URL=http://$host, MISP_MODULES_PORT=6666
    URL="${MISP_MODULES_URL}"
    case "${URL}" in
        http://*)
            URL="$(echo "${URL}" | sed -e 's,http://,,')"
            MISP_MODULES_PROTO="http://"
            MISP_MODULES_PORT="80"
            ;;
        https:*)
            URL="$(echo "${URL}" | sed -e 's,https://,,')"
            MISP_MODULES_PROTO="https://"
            MISP_MODULES_PORT="443"
            ;;
        *)
            MISP_MODULES_PROTO="http://"
            MISP_MODULES_PORT="6666"
            ;;
    esac
    case "${URL}" in
        *:*)
            MISP_MODULES_URL="${MISP_MODULES_PROTO}$(echo "${URL}" | sed -e 's,:.*,,')"
            MISP_MODULES_PORT="$(echo "${URL}" | sed -e 's,.*:,,')"
            ;;
        *)
            MISP_MODULES_URL="${MISP_MODULES_PROTO}${URL}"
            ;;
    esac
fi

MISP_BASE_PATH=/var/www/MISP
MISP_APP_PATH=${MISP_BASE_PATH}/app
MISP_APP_CONFIG_PATH=${MISP_APP_PATH}/Config
MISP_CONFIG=${MISP_APP_CONFIG_PATH}/config.php
DATABASE_CONFIG=${MISP_APP_CONFIG_PATH}/database.php
EMAIL_CONFIG=${MISP_APP_CONFIG_PATH}/email.php
CAKE_CONFIG="${MISP_APP_PATH}/Plugin/CakeResque/Config/config.php"
SSL_CERT="/etc/apache2/ssl/cert.pem"
SSL_KEY="/etc/apache2/ssl/key.pem"
SSL_DH_FILE="/etc/apache2/ssl/dhparams.pem"
FOLDER_with_VERSIONS="${MISP_APP_PATH}/tmp ${MISP_APP_PATH}/files ${MISP_APP_PATH}/Plugin/CakeResque/Config ${MISP_APP_CONFIG_PATH} ${MISP_BASE_PATH}/.gnupg ${MISP_BASE_PATH}/.smime /etc/apache2/ssl"
PID_CERT_CREATER="/etc/apache2/ssl/SSL_create.pid"

# defaults

( [ -z "$MISP_URL" ] && [ -z "$MISP_FQDN" ] ) && echo "Please set 'MISP_FQDN' or 'MISP_URL' environment variable in docker-compose.override.yml file for misp-server!!!" && exit
( [ -z "$MISP_URL" ] && [ ! -z "$MISP_FQDN" ] ) && MISP_URL="https://$(echo "$MISP_FQDN"|cut -d '/' -f 3)"
[ -z "$PGP_ENABLE" ] && PGP_ENABLE=0
[ -z "$SMIME_ENABLE" ] && SMIME_ENABLE=0
[ -z "$HTTPS_ENABLE" ] && HTTPS_ENABLE=y
[ -z "$MYSQL_HOST" ] && MYSQL_HOST=localhost
[ -z "$MYSQL_PORT" ] && MYSQL_PORT=3306
[ -z "$MYSQL_USER" ] && MYSQL_USER=misp
[ -z "$SENDER_ADDRESS" ] && SENDER_ADDRESS="no-reply@$MISP_FQDN"
[ -z "$MISP_SALT" ] && MISP_SALT="$(</dev/urandom tr -dc A-Za-z0-9 | head -c 50)"

[ -z "$CAKE" ] && CAKE="$MISP_APP_PATH/Console/cake"
[ -z "$MYSQLCMD" ] && MYSQLCMD="mysql -u $MYSQL_USER -p$MYSQL_PASSWORD -P $MYSQL_PORT -h $MYSQL_HOST -r -N  $MYSQL_DATABASE"

[ -z "${PHP_MEMORY_LIMIT}" ] && PHP_MEMORY_LIMIT="1024M"
[ -z "${PHP_MAX_EXECUTION_TIME}" ] && PHP_MAX_EXECUTION_TIME="900"
[ -z "${PHP_UPLOAD_MAX_FILESIZE}" ] && PHP_UPLOAD_MAX_FILESIZE="50M"
[ -z "${PHP_POST_MAX_SIZE}" ] && PHP_POST_MAX_SIZE="50M"

[ -z "$REDIS_FQDN" ] && REDIS_FQDN=localhost


init_pgp(){
    local PUBKEY="public.key"
    local PVTKEY="private.key"
    local FOLDER="${MISP_BASE_PATH}/.gnupg"

    if ! [ -f ${FOLDER}/${PVTKEY} ] && [ -n "${MISP_PGP_PRIVATE}" ]; then
        [ -d ${FOLDER} ] || mkdir -p ${FOLDER}
        echo "${MISP_PGP_PRIVATE}" >${FOLDER}/${PVTKEY}
    fi
    if ! [ -f ${FOLDER}/${PUBKEY} ] && [ -n "${MISP_PGP_PUBLIC}" ]; then
        [ -d ${FOLDER} ] || mkdir -p ${FOLDER}
        echo "${MISP_PGP_PUBLIC}" >${FOLDER}/${PUBKEY}
    fi
    if [ "$PGP_ENABLE" != "y" ]; then
        # if pgp should not be activated return
        echo "$STARTMSG PGP should not be activated."
        return
    elif [ ! -f ${FOLDER}/${PUBKEY} ]; then
        # if secring.pgp do not exists return
        echo "$STARTMSG PGP key $FOLDER/${PUBKEY} not found. Please add it. Sleeping 120 seconds..."
        sleep 120
        exit 1
    else
        chown -R www-data:www-data ${FOLDER}
        chmod 700 ${FOLDER}
        chmod 400 ${FOLDER}/*

        if [ -f ${FOLDER}/${PVTKEY} ] && [ -n "${MISP_PGP_PVTPASS}" ]; then
            echo "$STARTMSG PGP Adding ${FOLDER}/${PVTKEY} to the key ring..."
            echo "${MISP_PGP_PVTPASS}" >pass-file.$$
            GNUPGHOME=${FOLDER} gpg --batch --pinentry-mode=loopback --passphrase-file=pass-file.$$ --import ${FOLDER}/${PVTKEY}
            rm pass-file.$$
        fi

        PGP_ENABLE=true
        echo "$STARTMSG ###### PGP Key exists and copy it to MISP webroot #######"
        # Copy public key to the right place
        if [ -f ${MISP_APP_PATH}/webroot/gpg.asc ]; then rm ${MISP_APP_PATH}/webroot/gpg.asc; fi
        sudo -u www-data sh -c "cp ${FOLDER}/${PUBKEY} ${MISP_APP_PATH}/webroot/gpg.asc"
    fi
}

init_smime(){
    local FOLDER="${MISP_BASE_PATH}/.smime/cert.pem"
      
    if [ "$SMIME_ENABLE" != "y" ]; then 
        echo "$STARTMSG S/MIME should not be activated."
        return
    elif [ ! -f "$FOLDER" ]; then
        # If certificate do not exists exit
        echo "$STARTMSG No Certificate found in $FOLDER."
        return
    else
        SMIME_ENABLE=1
        echo "$STARTMSG ###### S/MIME Cert exists and copy it to MISP webroot #######" 
        ### Set permissions
        chown www-data:www-data ${MISP_BASE_PATH}/.smime
        chmod 500 ${MISP_BASE_PATH}/.smime
        ## the public certificate (for Encipherment) to the webroot
        sudo -u www-data sh -c "cp ${FOLDER} ${MISP_APP_PATH}/webroot/public_certificate.pem"
        #Due to this action, the MISP users will be able to download your public certificate (for Encipherment) by clicking on the footer
        ### Set permissions
        #chown www-data:www-data ${MISP_APP_PATH}/webroot/public_certificate.pem
        sudo -u www-data sh -c "chmod 440 ${MISP_APP_PATH}/webroot/public_certificate.pem"
    fi
    
}

start_apache() {
    # Apache gets grumpy about PID files pre-existing
    rm -f /run/apache2/apache2.pid
    # execute APACHE2
    /usr/sbin/apache2ctl -DFOREGROUND "$@"
}

add_analyze_column(){
    ORIG_FILE="${MISP_APP_PATH}/View/Elements/Events/eventIndexTable.ctp"
    PATCH_FILE="/eventIndexTable.patch"

    # Backup Orig File
    cp $ORIG_FILE ${ORIG_FILE}.bak
    # Patch file
    patch $ORIG_FILE < $PATCH_FILE
}

patch_misp() {
    local F
    [ -f $MISP_APP_CONFIG_PATH/core.php ] || cp $MISP_APP_CONFIG_PATH/core.default.php $MISP_APP_CONFIG_PATH/core.php

    F=${MISP_BASE_PATH}/INSTALL/MYSQL.sql
    if ! [ -f "${F}.orig" ]; then
        cp "${F}" "${F}.orig"
        sed\
            -e 's/^[[:blank:]]*CREATE TABLE `/CREATE TABLE IF NOT EXISTS `/'\
            -e 's/^[[:blank:]]*INSERT INTO /INSERT IGNORE INTO /'\
            "${F}.orig" >"${F}"
    fi
    F=${MISP_APP_PATH}/Lib/cakephp/lib/Cake/bootstrap.php
    if ! [ -f "${F}.orig" ]; then
        cp "${F}" "${F}.orig"
        sed -e "/if (!defined('FULL_BASE_URL')) {/a\\
        #if (Configure::read('App.fullBaseUrl')) {%\
        ##define('FULL_BASE_URL', Configure::read('App.fullBaseUrl'));%\
        #}%\
        }%\
        if (!defined('FULL_BASE_URL')) {" "${F}.orig"\
            | tr '#%' '\011\012' >"${F}"
    fi
    F=${MISP_APP_CONFIG_PATH}/core.php
    if ! [ -f "${F}.orig" ]; then
        if [ -f "${F}" ]; then
            cp "${F}" "${F}.orig"
        else
            cp ${MISP_APP_CONFIG_PATH}/core.default.php "${F}.orig"
        fi
        sed -e "/..Configure::write('App.baseUrl', env('SCRIPT_NAME'));/a\\
        Configure::write('App.fullBaseUrl', '$MISP_URL');" "${F}.orig"\
            >"${F}"
    fi
    echo "$STARTMSG patching MISP...finished"
}

change_php_vars(){
    for FILE in $(ls /etc/php/*/apache2/php.ini)
    do
        sed -i "s/memory_limit = .*/memory_limit = ${PHP_MEMORY_LIMIT}/" "$FILE"
        sed -i "s/max_execution_time = .*/max_execution_time = ${PHP_MAX_EXECUTION_TIME}/" "$FILE"
        sed -i "s/upload_max_filesize = .*/upload_max_filesize = ${PHP_UPLOAD_MAX_FILESIZE}/" "$FILE"
        sed -i "s/post_max_size = .*/post_max_size = ${PHP_POST_MAX_SIZE}/" "$FILE"
    done
}

init_misp_config(){
    echo "$STARTMSG Configure MISP | Copy MISP default configuration files"
    
    [ -f $MISP_APP_CONFIG_PATH/bootstrap.php ] || cp $MISP_APP_CONFIG_PATH/bootstrap.default.php $MISP_APP_CONFIG_PATH/bootstrap.php
    [ -f $DATABASE_CONFIG ] || cp $MISP_APP_CONFIG_PATH/database.default.php $DATABASE_CONFIG
    [ -f $MISP_APP_CONFIG_PATH/core.php ] || cp $MISP_APP_CONFIG_PATH/core.default.php $MISP_APP_CONFIG_PATH/core.php
    [ -f $MISP_CONFIG ] || cp $MISP_APP_CONFIG_PATH/config.default.php $MISP_CONFIG

    echo "$STARTMSG Configure MISP | Set DB User, Password and Host in database.php"
    sed -i "s/localhost/$MYSQL_HOST/" $DATABASE_CONFIG
    sed -i "s/db\s*login/$MYSQL_USER/" $DATABASE_CONFIG
    sed -i "s/8889/3306/" $DATABASE_CONFIG
    sed -i "s/db\s*password/$MYSQL_PASSWORD/" $DATABASE_CONFIG

    echo "$STARTMSG Configure MISP | Set MISP-Url in config.php"
    sed -i "s_.*baseurl.*=>.*_    \'baseurl\' => \'$MISP_URL\',_" $MISP_CONFIG
    #sudo >/dev/null 2>&1 $CAKE baseurl "$MISP_URL"

    echo "$STARTMSG Configure MISP | Set Email in config.php"
    sed -i "s/email@address.com/$SENDER_ADDRESS/" $MISP_CONFIG
    
    echo "$STARTMSG Configure MISP | Set Admin Email in config.php"
    sed -i "s/admin@misp.example.com/$SENDER_ADDRESS/" $MISP_CONFIG

    # echo "Configure MISP | Set GNUPG Homedir in config.php"
    # sed -i "s,'homedir' => '/',homedir'                        => '${MISP_BASE_PATH}/.gnupg'," $MISP_CONFIG

    echo "$STARTMSG Configure MISP | Change Salt in config.php"
    sed -i "s,'salt'\\s*=>\\s*'','salt'                        => '$MISP_SALT'," $MISP_CONFIG

    echo "$STARTMSG Configure MISP | Change Mail type from phpmailer to smtp"
    sed -i "s/'transport'\\s*=>\\s*''/'transport'                        => 'Smtp'/" $EMAIL_CONFIG
    
    #### CAKE ####
    echo "$STARTMSG Configure Cake | Change Redis host to $REDIS_FQDN"
    sed -i "s/'host' => 'localhost'.*/'host' => '$REDIS_FQDN',          \/\/ Redis server hostname/" $CAKE_CONFIG

    ##############
    echo # add an echo command because if no command is done busybox (alpine sh) won't continue the script
}

setup_via_cake_cli(){
    [ -f "${DATABASE_CONFIG}"  ] || (echo "$STARTMSG File ${DATABASE_CONFIG} not found. Exit now." && exit 1)
    if [ -f "${MISP_APP_CONFIG_PATH}/NOT_CONFIGURED" ]; then
        echo "$STARTMSG Cake initializing started..."
        # Initialize user and fetch Auth Key
        sudo -E $CAKE userInit -q
        #AUTH_KEY=$(mysql -u $MYSQL_USER -p$MYSQL_PASSWORD -h $MYSQL_HOST $MYSQL_DATABASE -e "SELECT authkey FROM users;" | head -2| tail -1)
        # Setup some more MISP default via cake CLI
        sudo >/dev/null 2>&1 $CAKE baseurl "$MISP_URL"
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.external_baseurl" "$MISP_URL"
        # Tune global time outs
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Session.autoRegenerate" 1
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Session.timeout" 600
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Session.cookieTimeout" 3600
        # Enable GnuPG
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "GnuPG.email" "$SENDER_ADDRESS"
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "GnuPG.homedir" "$MISP_BASE_PATH/.gnupg"
        if [ -n "${MISP_PGP_PVTPASS}" ]; then
            sudo >/dev/null 2>&1 $CAKE Admin setSetting "GnuPG.password" "${MISP_PGP_PVTPASS}"
        fi
        # Enable Enrichment set better timeouts
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Enrichment_services_enable" true
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Enrichment_services_url" "${MISP_MODULES_URL}"
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Enrichment_services_port" "${MISP_MODULES_PORT}"
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Enrichment_hover_enable" true
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Enrichment_timeout" 300
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Enrichment_hover_timeout" 150
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Enrichment_cve_advanced_enabled" true
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Enrichment_dns_enabled" true
        # Enable Import modules set better timout
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Import_services_enable" true
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Import_services_url" "${MISP_MODULES_URL}"
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Import_services_port" "${MISP_MODULES_PORT}"
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Import_timeout" 300
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Import_ocr_enabled" true
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Import_csvimport_enabled" true
        # Enable modules set better timout
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Export_services_enable" true
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Export_services_url" "${MISP_MODULES_URL}"
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Export_services_port" "${MISP_MODULES_PORT}"
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Export_timeout" 300
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Export_pdfexport_enabled" true
        # Enable installer org and tune some configurables
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.host_org_id" 1
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.email" "$SENDER_ADDRESS"
        #sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.disable_emailing" true
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.contact" "$SENDER_ADDRESS"
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.disablerestalert" true
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.showCorrelationsOnIndex" true
        # Provisional Cortex tunes
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Cortex_services_enable" false
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Cortex_services_url" "http://127.0.0.1"
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Cortex_services_port" 9000
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Cortex_timeout" 120
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Cortex_services_url" "http://127.0.0.1"
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Cortex_services_port" 9000
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Cortex_services_timeout" 120
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Cortex_services_authkey" ""
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Cortex_ssl_verify_peer" false
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Cortex_ssl_verify_host" false
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Cortex_ssl_allow_self_signed" true
        # Various plugin sightings settings
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Sightings_policy" 0
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Sightings_anonymise" false
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Sightings_range" 365
        # Plugin CustomAuth tuneable
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.CustomAuth_disable_logout" false
        # RPZ Plugin settings
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.RPZ_policy" "DROP"
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.RPZ_walled_garden" "127.0.0.1"
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.RPZ_serial" "\$date00"
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.RPZ_refresh" "2h"
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.RPZ_retry" "30m"
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.RPZ_expiry" "30d"
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.RPZ_minimum_ttl" "1h"
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.RPZ_ttl" "1w"
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.RPZ_ns" "localhost."
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.RPZ_ns_alt" ""
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.RPZ_email" "$SENDER_ADDRESS"
        # Force defaults to make MISP Server Settings less RED
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.language" "eng"
        #sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.proposals_block_attributes" false
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.default_event_tag_collection" "None"
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.proposals_block_attributes" "true"

        # Redis block
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.redis_host" "$REDIS_FQDN" 
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.redis_port" 6379
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.redis_database" 13
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.redis_password" ""
        sudo >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.ZeroMQ_redis_host" "$REDIS_FQDN"

        # Force defaults to make MISP Server Settings less YELLOW
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.ssdeep_correlation_threshold" 40
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.extended_alert_subject" false
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.default_event_threat_level" 4
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.newUserText" "Dear new MISP user,\\n\\nWe would hereby like to welcome you to the \$org MISP community.\\n\\n Use the credentials below to log into MISP at \$misp, where you will be prompted to manually change your password to something of your own choice.\\n\\nUsername: \$username\\nPassword: \$password\\n\\nIf you have any questions, don't hesitate to contact us at: \$contact.\\n\\nBest regards,\\nYour \$org MISP support team"
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.passwordResetText" "Dear MISP user,\\n\\nA password reset has been triggered for your account. Use the below provided temporary password to log into MISP at \$misp, where you will be prompted to manually change your password to something of your own choice.\\n\\nUsername: \$username\\nYour temporary password: \$password\\n\\nIf you have any questions, don't hesitate to contact us at: \$contact.\\n\\nBest regards,\\nYour \$org MISP support team"
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.enableEventBlacklisting" true
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.enableOrgBlacklisting" true
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.log_client_ip" false
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.log_auth" false
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.disableUserSelfManagement" false
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.block_event_alert" false
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.block_event_alert_tag" "no-alerts=\"true\""
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.block_old_event_alert" false
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.block_old_event_alert_age" ""
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.incoming_tags_disabled_by_default" false
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.footermidleft" "This is an initial install"
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.footermidright" "Please configure and harden accordingly"
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.welcome_text_top" "Initial Install, please configure"
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "MISP.welcome_text_bottom" "Welcome to MISP, change this message in MISP Settings"
        
        # Force defaults to make MISP Server Settings less GREEN
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Security.password_policy_length" 16
        # sudo >/dev/null 2>&1 $CAKE Admin setSetting "Security.password_policy_complexity" '/^((?=.*\d)|(?=.*\W+))(?![\n])(?=.*[A-Z])(?=.*[a-z]).*$|.{16,}/'

        # Set MISP Live
        sudo >/dev/null 2>&1 $CAKE Live 1
        # Update the galaxies…
        sudo >/dev/null 2>&1 $CAKE Admin updateGalaxies
        # Updating the taxonomies…
        sudo >/dev/null 2>&1 $CAKE Admin updateTaxonomies
        # Updating the warning lists…
        # sudo >/dev/null 2>&1 $CAKE Admin updateWarningLists
        # Updating the notice lists…
        # sudo >/dev/null 2>&1 $CAKE Admin updateNoticeLists
        #curl --header "Authorization: $AUTH_KEY" --header "Accept: application/json" --header "Content-Type: application/json" -k -X POST https://127.0.0.1/noticelists/update
        
        # Updating the object templates…
        # sudo >/dev/null 2>&1 $CAKE Admin updateObjectTemplates
        #curl --header "Authorization: $AUTH_KEY" --header "Accept: application/json" --header "Content-Type: application/json" -k -X POST https://127.0.0.1/objectTemplates/update
    else
        echo "$STARTMSG Cake setup: MISP is configured."
    fi
}

create_ssl_cert(){
    # If a valid SSL certificate is not already created for the server, create a self-signed certificate:
    while [ -f $PID_CERT_CREATER.proxy ]
    do
        echo "$STARTMSG $(date +%T) -  misp-proxy container create currently the certificate. misp-server wait until misp-proxy is finished."
        sleep 2
    done
    ( [ ! -f $SSL_CERT ] && [ ! -f $SSL_KEY ] ) && touch ${PID_CERT_CREATER}.server && echo "$STARTMSG Create SSL Certificate..." && openssl req -x509 -newkey rsa:4096 -keyout $SSL_KEY -out $SSL_CERT -days 365 -sha256 -subj "/CN=${HOSTNAME}" -nodes && rm ${PID_CERT_CREATER}.server
    echo # add an echo command because if no command is done busybox (alpine sh) won't continue the script
}

SSL_generate_DH(){
    while [ -f $PID_CERT_CREATER.proxy ]
    do
        echo "$STARTMSG $(date +%T) -  misp-proxy container create currently the certificate. misp-server wait until misp-proxy is finish."
        sleep 5
    done
    [ ! -f $SSL_DH_FILE ] && touch ${PID_CERT_CREATER}.server  && echo "$STARTMSG Create DH params - This can take a long time, so take a break and enjoy a cup of tea or coffee." && openssl dhparam -out $SSL_DH_FILE 2048 && rm ${PID_CERT_CREATER}.server
    echo # add an echo command because if no command is done busybox (alpine sh) won't continue the script
}

check_mysql(){
    # Test when MySQL is ready    

    # Test if entrypoint_local_mariadb.sh is ready
    sleep 5
    while (true)
    do
        [ ! -f /var/lib/mysql/entrypoint_local_mariadb.sh.pid ] && break
        sleep 5
    done

    # wait for Database come ready
    isDBup () {
        echo "SHOW STATUS" | $MYSQLCMD 1>/dev/null
        echo $?
    }

    RETRY=100
    until [ $(isDBup) -eq 0 ] || [ $RETRY -le 0 ] ; do
        echo "Waiting for database to come up"
        sleep 5
        RETRY=$(( $RETRY - 1))
    done
    if [ $RETRY -le 0 ]; then
        >&2 echo "Error: Could not connect to Database on $MYSQL_HOST:$MYSQL_PORT"
        exit 1
    fi

}

check_misp_modules(){
    while ! curl "${MISP_MODULES_URL}:${MISP_MODULES_PORT}/modules" >/dev/null 2>&1; do
        sleep 5
    done
}

init_mysql(){
    #####################################################################
    if [ -f "${MISP_APP_CONFIG_PATH}/NOT_CONFIGURED" ]; then
        check_mysql
        # import MISP DB Scheme
        echo "$STARTMSG ... importing MySQL scheme..."
        $MYSQLCMD < ${MISP_BASE_PATH}/INSTALL/MYSQL.sql
        echo "$STARTMSG MySQL import...finished"
    fi
    echo
}

check_redis(){
    # Test when Redis is ready
    while (true)
    do
        [ "$(redis-cli -h "$REDIS_FQDN" ping)" = "PONG" ] && break;
        echo "$STARTMSG Wait for Redis..."
        sleep 2
    done
}

upgrade(){
    for i in $FOLDER_with_VERSIONS
    do
        if [ ! -f "$i"/"${NAME}" ] 
        then
            # File not exist and now it will be created
            [ -d "$i" ] || mkdir -p "$i"
            echo "${VERSION}" > "$i"/"${NAME}"
        fi
        if [ -f "$i"/"${NAME}" ] && ! [ -s "$i"/"${NAME}" ]
        then
            # File exists, but is empty
            echo "${VERSION}" > "$i"/"${NAME}"
        elif [ "$VERSION" = "$(cat "$i"/"${NAME}")" ]
        then
            # File exists and the volume is the current version
            echo "$STARTMSG Folder $i is on the newest version."
        else
            # upgrade
            echo "$STARTMSG Folder $i should be updated."
            case "$(cat "$i"/"$NAME")" in
            2.4.92)
                # Tasks todo in 2.4.92
                echo "$STARTMSG #### Upgrade Volumes from 2.4.92 ####"
                ;;
            2.4.93)
                # Tasks todo in 2.4.92
                echo "$STARTMSG #### Upgrade Volumes from 2.4.93 ####"
                ;;
            2.4.94)
                # Tasks todo in 2.4.92
                echo "$STARTMSG #### Upgrade Volumes from 2.4.94 ####"
                ;;
            2.4.95)
                # Tasks todo in 2.4.92
                echo "$STARTMSG #### Upgrade Volumes from 2.4.95 ####"
                ;;
            2.4.96)
                # Tasks todo in 2.4.92
                echo "$STARTMSG #### Upgrade Volumes from 2.4.96 ####"
                ;;
            2.4.97)
                # Tasks todo in 2.4.92
                echo "$STARTMSG #### Upgrade Volumes from 2.4.97 ####"
                ;;
            *)
                echo "$STARTMSG Unknown Version, upgrade not possible."
                ;;
            esac
            ############ DO ANY!!!
        fi
    done
}

##############   MAIN   #################

echo "$STARTMSG patching MISP..." && patch_misp

# If a customer needs a analze column in misp
echo "$STARTMSG Check if analyze column should be added..." && [ "$ADD_ANALYZE_COLUMN" = "yes" ] && add_analyze_column

# Change PHP VARS
echo "$STARTMSG Change PHP values ..." && change_php_vars

##### PGP configs #####
echo "$STARTMSG Check if PGP should be enabled...." && init_pgp


echo "$STARTMSG Check if SMIME should be enabled..." && init_smime

if [ "$HTTPS_ENABLE" != "y" ]; then
echo "$STARTMSG HTTPS should not be activated."
else
##### create a cert if it is required
echo "$STARTMSG Check if a cert is required..." && create_ssl_cert

# check if DH file is required to generate
echo "$STARTMSG Check if a dh file is required" && SSL_generate_DH

##### enable https config and disable http config ####
echo "$STARTMSG Check if HTTPS MISP config should be enabled..."
    ( [ -f ${SSL_CERT} ] && [ ! -f /etc/apache2/sites-enabled/misp.ssl.conf ] ) && mv /etc/apache2/sites-enabled/misp.ssl /etc/apache2/sites-enabled/misp.ssl.conf

echo "$STARTMSG Check if HTTP MISP config should be disabled..."
    ( [ -f ${SSL_CERT} ] && [ -f /etc/apache2/sites-enabled/misp.conf ] ) && mv /etc/apache2/sites-enabled/misp.conf /etc/apache2/sites-enabled/misp.http
fi

##### check Redis
echo "$STARTMSG Check if Redis is ready..." && check_redis

##### check MySQL
echo "$STARTMSG Check if MySQL is ready..." && check_mysql

##### check misp-modules
echo "$STARTMSG Check if misp-modules is ready..." && check_misp_modules

##### Import MySQL scheme
echo "$STARTMSG Import MySQL scheme..." && init_mysql

##### initialize MISP-Server
echo "$STARTMSG Initialize misp base config..." && init_misp_config

##### check if setup is new: - in the dockerfile i create on this path a empty file to decide is the configuration completely new or not
echo "$STARTMSG Check if cake setup should be initialized..." && setup_via_cake_cli

##### Delete the initial decision file & reboot misp-server
echo "$STARTMSG Check if misp-server is configured and file ${MISP_APP_CONFIG_PATH}/NOT_CONFIGURED exist"
    [ -f ${MISP_APP_CONFIG_PATH}/NOT_CONFIGURED ] && echo "$STARTMSG delete init config file and reboot" && rm "${MISP_APP_CONFIG_PATH}/NOT_CONFIGURED"

# Disable MPM_EVENT Worker
echo "$STARTMSG Deactivate Apache2 Event Worker" && a2dismod mpm_event

########################################################
# check volumes and upgrade if it is required
echo "$STARTMSG Upgrade if it is required..." && upgrade


##### Check permissions #####
    echo "$STARTMSG Configure MISP | Check permissions..."
    #echo "$STARTMSG ... chown -R www-data.www-data ${MISP_BASE_PATH}..." && chown -R www-data.www-data ${MISP_BASE_PATH}
    echo "$STARTMSG ... chown -R www-data.www-data ${MISP_BASE_PATH}..." && find ${MISP_BASE_PATH} -not -user www-data -exec chown www-data.www-data {} +
    echo "$STARTMSG ... chmod -R 0750 ${MISP_BASE_PATH}..." && find ${MISP_BASE_PATH} -perm 550 -type f -exec chmod 0550 {} + && find ${MISP_BASE_PATH} -perm 770 -type d -exec chmod 0770 {} +
    echo "$STARTMSG ... chmod -R g+ws ${MISP_APP_PATH}/tmp..." && chmod -R g+ws ${MISP_APP_PATH}/tmp
    echo "$STARTMSG ... chmod -R g+ws ${MISP_APP_PATH}/files..." && chmod -R g+ws ${MISP_APP_PATH}/files
    echo "$STARTMSG ... chmod -R g+ws ${MISP_APP_PATH}/files/scripts/tmp" && chmod -R g+ws ${MISP_APP_PATH}/files/scripts/tmp

# delete pid file
[ -f $ENTRYPOINT_PID_FILE ] && rm $ENTRYPOINT_PID_FILE

# START APACHE2
echo "$STARTMSG ####################################  started Apache2 with cmd: '$CMD_APACHE' ####################################"

##### Display tips
echo
echo
cat <<__WELCOME__
" ###########	MISP environment is ready	###########"
" Please go to: ${MISP_URL}"
" Login credentials:"
"      Username: admin@admin.test"
"      Password: admin"
	
" Do not forget to change your SSL certificate with:    make change-ssl"
" ##########################################################"
Congratulations!
Your MISP-dockerized server has been successfully booted.
__WELCOME__


##### execute apache
[ "$CMD_APACHE" != "none" ] && start_apache "$CMD_APACHE"
[ "$CMD_APACHE" = "none" ] && start_apache
