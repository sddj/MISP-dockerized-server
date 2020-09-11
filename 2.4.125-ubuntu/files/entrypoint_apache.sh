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
MISP_APP_PATH=/var/www/MISP/app
MISP_APP_CONFIG_PATH=$MISP_APP_PATH/Config
MISP_CONFIG=$MISP_APP_CONFIG_PATH/config.php
DATABASE_CONFIG=$MISP_APP_CONFIG_PATH/database.php
EMAIL_CONFIG=$MISP_APP_CONFIG_PATH/email.php
CAKE_CONFIG="/var/www/MISP/app/Plugin/CakeResque/Config/config.php"
SSL_CERT="/etc/apache2/ssl/cert.pem"
SSL_KEY="/etc/apache2/ssl/key.pem"
SSL_DH_FILE="/etc/apache2/ssl/dhparams.pem"
FOLDER_with_VERSIONS="/var/www/MISP/app/tmp /var/www/MISP/app/files /var/www/MISP/app/Plugin/CakeResque/Config /var/www/MISP/app/Config /var/www/MISP/.gnupg /var/www/MISP/.smime /etc/apache2/ssl"
PID_CERT_CREATER="/etc/apache2/ssl/SSL_create.pid"

# defaults

( [ -z "$MISP_URL" ] && [ -z "$MISP_FQDN" ] ) && echo "Please set 'MISP_FQDN' or 'MISP_URL' environment variable in docker-compose.override.yml file for misp-server!!!" && exit
( [ -z "$MISP_URL" ] && [ ! -z "$MISP_FQDN" ] ) && MISP_URL="https://$(echo "$MISP_FQDN"|cut -d '/' -f 3)"
[ -z "$PGP_ENABLE" ] && PGP_ENABLE=n
[ -z "$SMIME_ENABLE" ] && SMIME_ENABLE=n
[ -z "$HTTPS_ENABLE" ] && HTTPS_ENABLE=y
[ -z "$MYSQL_HOST" ] && MYSQL_HOST=localhost
[ -z "$MYSQL_PORT" ] && MYSQL_PORT=3306
[ -z "$MYSQL_USER" ] && MYSQL_USER=misp
[ -z "$SENDER_ADDRESS" ] && SENDER_ADDRESS="no-reply@$MISP_FQDN"
[ -z "$MISP_SALT" ] && MISP_SALT="$(</dev/urandom tr -dc A-Za-z0-9 | head -c 50)"

[ -z "$CAKE" ] && CAKE="$MISP_APP_PATH/Console/cake"
Q=""
[ -z "$MYSQLCMD" ] && MYSQLCMD="mysql -u $MYSQL_USER -p$MYSQL_PASSWORD -P $MYSQL_PORT -h $MYSQL_HOST -r -N  $MYSQL_DATABASE"

[ -z "${PHP_MEMORY_LIMIT}" ] && PHP_MEMORY_LIMIT="1024M"
[ -z "${PHP_MAX_EXECUTION_TIME}" ] && PHP_MAX_EXECUTION_TIME="900"
[ -z "${PHP_UPLOAD_MAX_FILESIZE}" ] && PHP_UPLOAD_MAX_FILESIZE="50M"
[ -z "${PHP_POST_MAX_SIZE}" ] && PHP_POST_MAX_SIZE="50M"

[ -z "$REDIS_FQDN" ] && REDIS_FQDN=localhost


patch_misp() {
    local patch

    if [ -f /patches.d/patched ]; then
        echo "$STARTMSG patching MISP...already patched"
    else
        echo "$STARTMSG patching MISP..."
        touch /patches.d/patched
        if [ -f /patches.d/debug ]; then
            rsync -aS $MISP_BASE_PATH/ $MISP_BASE_PATH.orig
        fi
        pushd /
        for patch in $(ls -1 /patches.d/*.sh 2>/dev/null); do
            "${patch}"
        done
        for patch in $(ls -1 /patches.d/*.patch 2>/dev/null); do
            patch -p0 <"${patch}"
        done
        popd

        touch /patches.d/php.log; chmod a+rw /patches.d/php.log
        echo "$STARTMSG patching MISP...finished"
    fi
}

init_pgp(){
    local FOLDER="${MISP_BASE_PATH}/.gnupg"
    
    if [ ! $PGP_ENABLE == "y" ]; then
        # if pgp should not be activated return
        echo "$STARTMSG PGP should not be activated."
        return
    fi
    if [ ! -f ${FOLDER}/private.key ] && [ -n "${MISP_PGP_PRIVATE}" ]; then
        [ -d ${FOLDER} ] || mkdir -p ${FOLDER}
        echo "${MISP_PGP_PRIVATE}" >${FOLDER}/private.key
    fi
    if [ ! -f ${FOLDER}/public.key ] && [ -n "${MISP_PGP_PUBLIC}" ]; then
        [ -d ${FOLDER} ] || mkdir -p ${FOLDER}
        echo "${MISP_PGP_PUBLIC}" >${FOLDER}/public.key
    fi
    if [ ! -f "$FOLDER/public.key" ]; then
        # if secring.pgp do not exists return
        echo "$STARTMSG GNU PGP Key isn't existing. Please add them. sleep 120 seconds"
        sleep 120
        exit 1
    else
        echo "$STARTMSG ###### PGP Key exists and copy it to MISP webroot #######"
        if [ -f ${FOLDER}/private.key ] && [ -n "${MISP_PGP_PVTPASS}" ]; then
            echo "$STARTMSG PGP Adding ${FOLDER}/private.key to the key ring..."
            echo "${MISP_PGP_PVTPASS}" >pass-file.$$
            GNUPGHOME=${FOLDER} gpg --batch --pinentry-mode=loopback --passphrase-file=pass-file.$$ --import ${FOLDER}/private.key
            rm pass-file.$$
        fi
        chown -R www-data:www-data ${FOLDER}
        chmod 700 ${FOLDER}
        chmod 400 ${FOLDER}/*

        # Copy public key to the right place
        [ -f ${MISP_APP_PATH}/webroot/gpg.asc ] && rm ${MISP_APP_PATH}/webroot/gpg.asc
        sudo -u www-data sh -c "cp ${FOLDER}/public.key ${MISP_APP_PATH}/webroot/gpg.asc"
    fi
}

init_smime(){
    local FOLDER="/var/www/MISP/.smime/cert.pem"
      
    if [ ! $SMIME_ENABLE == "y" ]; then 
        echo "$STARTMSG S/MIME should not be activated."
        return
    elif [ -f "$FOLDER" ]; then
        # If certificate do not exists exit
        echo "$STARTMSG No Certificate found in $FOLDER."
        return
    else
        echo "$STARTMSG ###### S/MIME Cert exists and copy it to MISP webroot #######" 
        ### Set permissions
        chown www-data:www-data /var/www/MISP/.smime
        chmod 500 /var/www/MISP/.smime
        ## the public certificate (for Encipherment) to the webroot
        sudo -u www-data sh -c "cp /var/www/MISP/.smime/cert.pem /var/www/MISP/app/webroot/public_certificate.pem"
        #Due to this action, the MISP users will be able to download your public certificate (for Encipherment) by clicking on the footer
        ### Set permissions
        #chown www-data:www-data /var/www/MISP/app/webroot/public_certificate.pem
        sudo -u www-data sh -c "chmod 440 /var/www/MISP/app/webroot/public_certificate.pem"
    fi
    
}

start_apache() {
    # check if a PID file exists 
    if [[ -e /run/apache2/apache2.pid ]]; then
        rm -f /run/apache2/apache2.pid
    fi
    # execute APACHE2
    /usr/sbin/apache2ctl -DFOREGROUND "$@"
}

add_analyze_column(){
    ORIG_FILE="/var/www/MISP/app/View/Elements/Events/eventIndexTable.ctp"
    PATCH_FILE="/eventIndexTable.patch"

    # Backup Orig File
    cp $ORIG_FILE ${ORIG_FILE}.bak
    # Patch file
    patch $ORIG_FILE < $PATCH_FILE
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
    if [[ ! -e $MISP_APP_CONFIG_PATH/core.php ]]; then
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
        sed -i "s_.*baseurl.*=>.*_    'baseurl' => '$MISP_URL',_" $MISP_CONFIG
        #sudo $Q >/dev/null 2>&1 $CAKE baseurl "$MISP_URL"
        sed -i "s/.*'org'.*=>.*/    'org' => 'ROOT','host_org_id' => 1,/" $MISP_CONFIG

        echo "$STARTMSG Configure MISP | Set Email in config.php"
        sed -i "s/email@address.com/$SENDER_ADDRESS/" $MISP_CONFIG
        
        echo "$STARTMSG Configure MISP | Set Admin Email in config.php"
        sed -i "s/admin@misp.example.com/$SENDER_ADDRESS/" $MISP_CONFIG

        # echo "Configure MISP | Set GNUPG Homedir in config.php"
        # sed -i "s,'homedir' => '/',homedir'                        => '/var/www/MISP/.gnupg'," $MISP_CONFIG

        echo "$STARTMSG Configure MISP | Change Salt in config.php"
        sed -i "s,'salt'\\s*=>\\s*'','salt'                        => '$MISP_SALT'," $MISP_CONFIG

        echo "$STARTMSG Configure MISP | Change Mail type from phpmailer to smtp"
        sed -i "s/'transport'\\s*=>\\s*''/'transport'                        => 'Smtp'/" $EMAIL_CONFIG
        
        #### CAKE ####
        echo "$STARTMSG Configure Cake | Change Redis host to $REDIS_FQDN"
        sed -i "s/'host' => 'localhost'.*/'host' => '$REDIS_FQDN',          \/\/ Redis server hostname/" $CAKE_CONFIG

        ##############
        echo # add an echo command because if no command is done busybox (alpine sh) won't continue the script
    else
        echo "$STARTMSG MISP allready configured"
    fi
}

setup_python_venv_CAKE(){
    if grep -q "${MISP_MODULES_URL}" /var/www/MISP/app/Config/config.php && grep -q "/var/www/MISP/venv/bin/python" /var/www/MISP/app/Config/config.php; then
        echo "$STARTMSG MISP initial configuration allready done - skipping"
    else
        echo "$STARTMSG Setting python venv via CAKE..."
        # Set python path
        sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "MISP.python_bin" "/var/www/MISP/venv/bin/python"
    fi
}

setup_redis_CAKE(){
    if grep -q "${MISP_MODULES_URL}" /var/www/MISP/app/Config/config.php && grep -q "/var/www/MISP/venv/bin/python" /var/www/MISP/app/Config/config.php; then
        echo "$STARTMSG MISP initial configuration allready done - skipping"
    else
        echo "$STARTMSG Setting Redis settings via CAKE..."
        sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "MISP.redis_host" "$REDIS_FQDN"
        sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "MISP.redis_port" "${REDIS_PORT:-6379}"
        sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "MISP.redis_database" "${REDIS_DATABASE:-13}"
        sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "MISP.redis_password" "${REDIS_PW:-}"
        sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.ZeroMQ_redis_host" "$REDIS_FQDN"
    fi
}

setup_misp_modules_CAKE(){
    #if [[ ! -e $MISP_APP_CONFIG_PATH/core.php ]]; then

    ### We assume that both the python venv and misp modules are unset - if not, the instance was allready configured 
    if grep -q "${MISP_MODULES_URL}" /var/www/MISP/app/Config/config.php && grep -q "/var/www/MISP/venv/bin/python" /var/www/MISP/app/Config/config.php; then
        echo "$STARTMSG MISP initial configuration allready done - skipping"
    else
        echo "$STARTMSG Setting MISP-Modules settings via CAKE..."
        # Enable Enrichment 
        sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Enrichment_services_url" "${MISP_MODULES_URL}"
        sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Enrichment_services_port" "${MISP_MODULES_PORT}"
        sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Enrichment_services_enable" true
        sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Enrichment_hover_enable" true
        sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Enrichment_timeout" 300
        sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Enrichment_hover_timeout" 150
        sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Enrichment_cve_advanced_enabled" true
        sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Enrichment_dns_enabled" true
        # Enable Import modules set better timout
        sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Import_services_url" "${MISP_MODULES_URL}"
        sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Import_services_port" "${MISP_MODULES_PORT}"
        sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Import_services_enable" true
        sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Import_timeout" 300
        #sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Import_ocr_enabled" true
        #sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Import_csvimport_enabled" true
        # Enable modules set better timout
        sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Export_services_url" "${MISP_MODULES_URL}"
        sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Export_services_port" "${MISP_MODULES_PORT}"
        sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Export_services_enable" true
        sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Export_timeout" 300
        #sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Export_pdfexport_enabled" true
        sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "Plugin.Cortex_services_enable" false
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

check_misp_modules(){
    while ! curl "${MISP_MODULES_URL}:${MISP_MODULES_PORT}/modules" >/dev/null 2>&1; do
        sleep 5
    done
}

check_mysql(){
    # Test when MySQL is ready    

    # Test if entrypoint_local_mariadb.sh is ready
    if [ "${MYSQL_HOST}" == localhost ]; then
    sleep 5
    while (true)
    do
        #[ ! -f /var/lib/mysql/entrypoint_local_mariadb.sh.pid ] && break
        #sleep 5
        if [[ ! -e /var/lib/mysql/misp/users.ibd ]]; then
            echo "$STARTMSG ... wait until mariadb entrypoint has completly created the database"
        else            
            echo "$STARTMSG misp database created or allready exist" && break
        fi
        sleep 5
    done
    fi

    # wait for Database come ready
    isDBup () {
        echo "SHOW STATUS" | $MYSQLCMD 1>/dev/null 2>&1
        echo $?
    }

    doesDBexist () {
        echo "SELECT * FROM information_schema.tables WHERE table_schema = 'misp' AND table_name = 'logs' LIMIT 1;" | $MYSQLCMD
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
    elif [ -z "$(doesDBexist)" ]; then
        echo "$STARTMSG ... importing MySQL scheme..."
        $MYSQLCMD < /var/www/MISP/INSTALL/MYSQL.sql
        echo "$STARTMSG MySQL import...finished"
    fi

}

check_redis(){
    # Test when Redis is ready
    while (true)
    do
        [ "$(redis-cli -h "$REDIS_FQDN" ping)" == "PONG" ] && break;
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
        elif [ -f "$i"/"${NAME}" ] && [ -z "$(cat "$i"/"${NAME}")" ]
        then
            # File exists, but is empty
            echo "${VERSION}" > "$i"/"${NAME}"
        elif [ "$VERSION" == "$(cat "$i"/"${NAME}")" ]
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

echo "$STARTMSG Apply patches ..." && patch_misp

# If a customer needs a analze column in misp
echo "$STARTMSG Check if analyze column should be added..." && [ "$ADD_ANALYZE_COLUMN" == "yes" ] && add_analyze_column

# Change PHP VARS
echo "$STARTMSG Change PHP values ..." && change_php_vars

##### PGP configs #####
echo "$STARTMSG Check if PGP should be enabled...." && init_pgp


echo "$STARTMSG Check if SMIME should be enabled..." && init_smime

if [ ! "${HTTPS_ENABLE}" == "y" ]; then
    echo "$STARTMSG HTTPS should not be activated."
else
##### create a cert if it is required
echo "$STARTMSG Check if a cert is required..." && create_ssl_cert

# check if DH file is required to generate
echo "$STARTMSG Check if a dh file is required" && SSL_generate_DH

##### enable https config and disable http config ####
echo "$STARTMSG Check if HTTPS MISP config should be enabled..."
    ( [ -f /etc/apache2/ssl/cert.pem ] && [ ! -f /etc/apache2/sites-enabled/misp.ssl.conf ] ) && mv /etc/apache2/sites-enabled/misp.ssl /etc/apache2/sites-enabled/misp.ssl.conf

echo "$STARTMSG Check if HTTP MISP config should be disabled..."
    ( [ -f /etc/apache2/ssl/cert.pem ] && [ ! -f /etc/apache2/sites-enabled/misp.conf ] ) && mv /etc/apache2/sites-enabled/misp.conf /etc/apache2/sites-enabled/misp.http
fi

##### check Redis
echo "$STARTMSG Check if Redis is ready..." && check_redis

##### check MySQL
echo "$STARTMSG Check if MySQL is ready..." && check_mysql

##### check misp-modules
echo "$STARTMSG Check if misp-modules is ready..." && check_misp_modules

##### initialize MISP-Server
echo "$STARTMSG Initialize misp base config..." && init_misp_config

##### check if setup is new: - in the dockerfile i create on this path a empty file to decide is the configuration completely new or not
#echo "$STARTMSG Check if cake setup should be initialized..." && setup_via_cake_cli

##### Set Redis settings
echo "$STARTMSG Setup redis in MISP" && setup_redis_CAKE

##### Set MISP-Modules settings
echo "$STARTMSG Setup MISP-Modules in MISP" && setup_misp_modules_CAKE

##### Set Python Venv
echo "$STARTMSG Setup Python venv in MISP" && setup_python_venv_CAKE

# Disable MPM_EVENT Worker
echo "$STARTMSG Deactivate Apache2 Event Worker" && a2dismod mpm_event

########################################################
# check volumes and upgrade if it is required
echo "$STARTMSG Upgrade if it is required..." && upgrade

sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "MISP.external_baseurl" "$MISP_URL"
sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "MISP.language" "${MISP_LANG:-eng}"
sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "MISP.default_event_tag_collection" "${MISP_DETC:-}"
sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "MISP.proposals_block_attributes" "${MISP_PBA:-true}"
sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "GnuPG.email" "$SENDER_ADDRESS"
sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "GnuPG.homedir" "$MISP_BASE_PATH/.gnupg"
if [ -n "${MISP_PGP_PVTPASS}" ]; then sudo $Q >/dev/null 2>&1 $CAKE Admin setSetting "GnuPG.password" "${MISP_PGP_PVTPASS}"; fi
sudo $Q >/dev/null 2>&1 $CAKE Admin updateGalaxies
sudo $Q >/dev/null 2>&1 $CAKE Admin updateTaxonomies
sudo $Q >/dev/null 2>&1 $CAKE Admin updateWarningLists
sudo $Q >/dev/null 2>&1 $CAKE Admin updateNoticeLists
#sudo $Q >/dev/null 2>&1 $CAKE Admin updateObjectTemplates
sudo $Q >/dev/null 2>&1 $CAKE Live 1

##### Check permissions #####
echo "$STARTMSG Configure MISP | Check if permissions are still ok..."
#echo "$STARTMSG ... chown -R www-data.www-data /var/www/MISP..." && chown -R www-data.www-data /var/www/MISP
#echo "$STARTMSG ... chown -R www-data.www-data /var/www/MISP..." && find /var/www/MISP -not -user www-data -exec chown www-data.www-data {} +
#echo "$STARTMSG ... chmod -R 0750 /var/www/MISP..." && find /var/www/MISP -perm 550 -type f -exec chmod 0550 {} + && find /var/www/MISP -perm 770 -type d -exec chmod 0770 {} +
#echo "$STARTMSG ... chmod -R g+ws /var/www/MISP/app/tmp..." && chmod -R g+ws /var/www/MISP/app/tmp
#echo "$STARTMSG ... chmod -R g+ws /var/www/MISP/app/files..." && chmod -R g+ws /var/www/MISP/app/files
#echo "$STARTMSG ... chmod -R g+ws /var/www/MISP/app/files/scripts/tmp" && chmod -R g+ws /var/www/MISP/app/files/scripts/tmp
sudo chown -R www-data:www-data ${MISP_BASE_PATH}/*
sudo chmod -R 750 ${MISP_BASE_PATH}/app/Config

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
#[ "$CMD_APACHE" != "none" ] && start_apache "$CMD_APACHE"
#[ "$CMD_APACHE" == "none" ] && start_apache
#service apache2 start
start_apache "$@"
