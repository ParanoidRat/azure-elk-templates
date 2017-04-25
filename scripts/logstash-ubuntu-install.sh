#!/bin/bash
# see http://redsymbol.net/articles/unofficial-bash-strict-mode/
# for explanation of set options
set -euo pipefail
IFS=$'\n\t'

#########################
# Global vars
#########################
DEBUG=1

# Script parameters
LOGSTASH_VERSION="5.3.0"
INSTALL_ADDITIONAL_PLUGINS=""
ES_URI="http://10.0.0.4:9200"
REDIS_HOST="some.domain.com"
REDIS_PORT="6380"
REDIS_PASSWORD="ChangeMe"
REDIS_KEY="logstash"


#########################
# Functions
#########################

help()
{
    echo "This script installs Logstash on Ubuntu"
    echo "Parameters:"
    echo "-V <version> Logstash version (e.g. 5.3.0)"
    echo "-L <plugin;plugin> install additional plugins"
    echo "-U <uri> Elasticsearch URI for output (e.g. http://10.0.0.4:9200)"
    echo "-R <host> Redis host for Logstash input (e.g. some.domain.com)"
    echo "-P <port> Redis SSL port for Logstash input (e.g. 6380)"
    echo "-W <password> Redis password Logstash input (e.g. ChageMe)"
    echo "-K <key> Redis list name for Logstash to read inputs (e.g. logstash)"
    echo "-h view this help content"
}

log()
{
    echo \[$(date '+%Y-%m-%d %H:%M:%S')\] "$1"
    if [ ! $DEBUG ]; then echo \[$(date '+%Y-%m-%d %H:%M:%S')\] "$1" >> /var/log/arm-install.log; fi
}

run_cmd()
{
  # temporarily disable the exit-immediately-on-error option
  set +e
  (
    # execute command
    if eval "$@"; then
      if [ $DEBUG ]; then log "[run_cmd][+] $@"; fi
    else
      log "[run_cmd][!] $@"
    fi
  )
  # re-enable the exit-immediately-on-error option
  set -e
}

check_install_pkg()
{
    local RETRY_T="15"

    log "[check_install_pkg_$@] Checking if '$@' is installed ..."
    set +e
    (
      if $(dpkg-query -W -f='${Status}' $@ 2>/dev/null | grep -q '^install ok installed$'); then
        log "[install_$@]   '$@' already present..."
        return
      else
        log "[check_install_pkg_$@]   Installing '$@' ..."
        run_cmd "(apt-get -yq install $@ || (sleep $RETRY_T; apt-get -yq install $@))"
      fi
    )
    set -e
}

check_start_service()
{
    local RETRY_T="5"
    local RETRY_N="3"

    log "[check_start_service_$@] Checking for running service '$@' ..."
    set +e
    (
      if $(systemctl is-active $@.service >/dev/null); then
        log "[check_start_service_$@]   Service '$@' already running, moving on..."
        return
      else
        for i in $(seq $RETRY_N); do
            log "[check_start_service_$@]   Attempt ${i}/$RETRY_N to start '$@'"
            if $(systemctl start $@.service; sleep 3; systemctl is-active $@.service); then
              log "[check_start_service_$@]   Service '$@' started successfully"
            else
              log "[check_start_service_$@]   Something is wrong... Pausing for $RETRY_T sec"
              sleep $RETRY_T
            fi
        done
      fi
    )
    set -e
}

install_java()
{
    log "[install_java] adding APT repository for oracle-java8..."
    run_cmd "(add-apt-repository -y ppa:webupd8team/java || (sleep 15; add-apt-repository -y ppa:webupd8team/java))"
    
    log "[install_java] 'apt-get update' started..."
    run_cmd "(apt-get -y update || (sleep 15; apt-get -y update)) > /dev/null"

    log "[install_java] accepting oracle license..."
    run_cmd "(echo debconf shared/accepted-oracle-license-v1-1 select true | debconf-set-selections)"
    run_cmd "(echo debconf shared/accepted-oracle-license-v1-1 seen true | debconf-set-selections)"
    
    log "[install_java] oracle-java8 install started..."
    run_cmd "(apt-get -yq install oracle-java8-installer || (sleep 15; apt-get -yq install oracle-java8-installer))"
    run_cmd "(command -v java >/dev/null 2>&1 || { sleep 15; rm /var/cache/oracle-jdk8-installer/jdk-*; apt-get install -f; })"

    #if the previous did not install correctly we go nuclear, otherwise this loop will early exit
    for i in $(seq 4); do
      if $(command -v java >/dev/null 2>&1); then
        log "[install_java] oracle-java8 install ended"
        return
      else
        log "[install_java] oracle-java8 install NOT successful, going nuclear..."
        run_cmd "(sleep 5)"
        run_cmd "(rm /var/cache/oracle-jdk8-installer/jdk-*;)"
        run_cmd "(rm -f /var/lib/dpkg/info/oracle-java8-installer*)"
        run_cmd "(rm /etc/apt/sources.list.d/*java*)"
        run_cmd "(apt-get -yq purge oracle-java8-installer*)"
        run_cmd "(apt-get -yq autoremove)"
        run_cmd "(apt-get -yq clean)"
        run_cmd "(add-apt-repository -y ppa:webupd8team/java || (sleep 15; add-apt-repository -y ppa:webupd8team/java))"
        run_cmd "(apt-get -yq update)"
        run_cmd "(apt-get -yq install --reinstall oracle-java8-installer)"
        log "[install_java] Seeing if oracle-java8 is installed after nuclear retry ${i}/4"
      fi
    done
    command -v java >/dev/null 2>&1 || { log "oracle-java8 install NOT successful after 4 forced re-installation retries, ABORT! ABORT!" >&2; exit 50; }
}

install_logstash()
{
    log "[install_logstash] Logstash $LOGSTASH_VERSION install started..."
    if [[ "${LOGSTASH_VERSION}" == \2* ]]; then
        DOWNLOAD_URL="https://download.elastic.co/logstash/logstash/packages/debian/logstash-$LOGSTASH_VERSION_all.deb"
    elif [[ "${LOGSTASH_VERSION}" == \5* ]]; then
        DOWNLOAD_URL="https://artifacts.elastic.co/downloads/logstash/logstash-$LOGSTASH_VERSION.deb"
    else
        DOWNLOAD_URL="https://artifacts.elastic.co/downloads/logstash/logstash-$LOGSTASH_VERSION.deb"
    fi

    log "[install_logstash] Downloading .deb package @ $DOWNLOAD_URL ..."
    run_cmd "(wget -q '$DOWNLOAD_URL' -O logstash-$LOGSTASH_VERSION.deb)"
    
    log "[install_logstash] Installing logstash-$LOGSTASH_VERSION.deb ..."
    run_cmd "(dpkg -i logstash-$LOGSTASH_VERSION.deb)"

    if [[ "${LOGSTASH_VERSION}" == \2* ]]; then
      log "[install_logstash] Disable Logstash SysV init scripts (will be using monit)"
      run_cmd "(update-rc.d logstash disable)"
    fi
}

plugin_cmd()
{
    if [[ "${LOGSTASH_VERSION}" == \5* ]]; then
      echo /usr/share/logstash/bin/logstash-plugin
    else
      echo /usr/share/logstash/bin/plugin
    fi
}

install_additional_plugins()
{
    local SKIP_PLUGINS="license"
 
    log "[install_additional_plugins] Additional Logstash plugins install started..."
    
    for PLUGIN in $(echo $INSTALL_ADDITIONAL_PLUGINS | tr ";" "\n")
    do
        if [[ $SKIP_PLUGINS =~ $PLUGIN ]]; then
            log "[install_additional_plugins] Skipping plugin '$PLUGIN'"
        else
            log "[install_additional_plugins] Install for '$PLUGIN' plugin started..."
            run_cmd "($(plugin_cmd) install $PLUGIN)"
        fi
    done
}

configure_logstash()
{
    local LS_CONF_R=/etc/logstash/conf.d/010-redis-input.conf
    local LS_CONF_ES=/etc/logstash/conf.d/020-elastic-output.conf

    log "[configure_logstash] Logstash configuration started..."

    log "[configure_logstash] Generating $LS_CONF_R..."
    log "[configure_logstash] Redis defined as '$REDIS_HOST:$REDIS_PORT'"
    log "[configure_logstash] Redis channel defined as '$REDIS_KEY'"
    (
        echo -e "input {"
        echo -e "  redis {"
        echo -e "    host => \"localhost\""
        echo -e "    port => \"6379\""
        echo -e "    password => \"$REDIS_PASSWORD\""
        echo -e "    data_type => \"list\""
        echo -e "    key => \"$REDIS_KEY\""
        echo -e "    threads => 4"
        echo -e "  }"
        echo -e "}"
    ) > $LS_CONF_R

    log "[configure_logstash] Generating $LS_CONF_ES..."
    log "[configure_logstash] Elasticsearch output URI defined as '$ES_URI'"
    (
        echo -e "output {"
        echo -e "  elasticsearch {"
        echo -e "    hosts => [\"$ES_URI\"]"
        echo -e "  }"
        echo -e "}"
    ) > $LS_CONF_ES    
}

install_monit()
{
    local MONIT_CONF=/etc/monit/monitrc

    log "[install_monit] Installing monit if not present ..."
    check_install_pkg "monit"
    
    log "[install_monit] Checking for old version of $MONIT_CONF ..."
    set +e
    (
      if [[ -f "$MONIT_CONF" ]]; then
        log "[install_monit]   $MONIT_CONF already present, backing up..."
        run_cmd "(mv $MONIT_CONF $MONIT_CONF-$(date '+%Y%m%d%H%M%S').bak)"
      else
        log "[install_monit]   $MONIT_CONF does not exist"
      fi
    )
    set -e

    log "[install_monit] Generating new $MONIT_CONF ..."
    {
        echo -e "set daemon 120"
        echo -e "  with start delay 240"
        echo -e ""
        echo -e "set logfile /var/log/monit.log"
        echo -e "set idfile /var/lib/monit/id"
        echo -e "set statefile /var/lib/monit/state"
        echo -e ""
        echo -e "set httpd port 2812 and"
        echo -e "    use address localhost"
        echo -e "    allow localhost" 
        echo -e ""
        echo -e "include /etc/monit/conf.d/*"
    } > $MONIT_CONF

    log "[install_monit] Starting monit if not running..."
    check_start_service "monit"
}

configure_monit_logstash()
{
    local MONIT_CONF=/etc/monit/conf.d/logstash.conf
    
    log "[configure_monit_logstash] Generating logstash conf for monit @ $MONIT_CONF"
    run_cmd "(touch $MONIT_CONF)"
    {
        echo -e "check process logstash matching \"logstash/runner.rb\""
        echo -e "  group logstash"
        echo -e "  start program = \"/bin/systemctl start logstash.service\""
        echo -e "  stop program = \"/bin/systemctl stop logstash.service\""
    } > $MONIT_CONF      

    log "[configure_monit_logstash] Reloading monit and starting logstash services..."
    run_cmd "(monit reload)"
    run_cmd "(monit start logstash)"
}

configure_monit_stunnel()
{
    local MONIT_CONF=/etc/monit/conf.d/stunnel.conf
    
    log "[configure_monit_stunnel] Generating stunnel conf for monit @ $MONIT_CONF"
    run_cmd "(touch $MONIT_CONF)"
    {
        echo -e "check process stunnel_az_redis with pidfile /var/run/stunnel4/az-redis.pid"
        echo -e "  group stunnel_redis"
        echo -e "  start program = \"/bin/systemctl start stunnel4.service\""
        echo -e "  stop program = \"/bin/systemctl stop stunnel4.service\""
    } > $MONIT_CONF      

    log "[configure_monit_stunnel] Reloading monit and starting stunnel services..."
    run_cmd "(monit reload)"
    run_cmd "(monit start stunnel)"
}

install_stunnel()
{
    local ST_AZ_REDIS_CONF=/etc/stunnel/az-redis.conf

    log "[install_stunnel] Stunnel install started..."
    run_cmd "(apt-get -yq install stunnel || (sleep 15; apt-get -yq install stunnel))"
    
    log "[install_stunnel] Generating stunnel config @ $ST_AZ_REDIS_CONF ..."
    {
        echo -e "setuid = stunnel4"
        echo -e "setgid = stunnel4"
        echo -e ""
        echo -e "pid = /var/run/stunnel4/az-redis.pid"
        echo -e ""
        echo -e "debug = notice"
        echo -e "output = /var/log/stunnel4/az-redis.log"
        echo -e ""
        echo -e "options = NO_SSLv2"
        echo -e "options = NO_SSLv3"
        echo -e ""
        echo -e "[az-redis]"
        echo -e "  client = yes"
        echo -e "  accept = localhost:6379"
        echo -e "  connect = $REDIS_HOST:$REDIS_PORT"
    } > $ST_AZ_REDIS_CONF

    local ST_DEFAULT=/etc/default/stunnel4

    log "[install_stunnel] Enabling tunnels in main config @ $ST_DEFAULT ..."
    run_cmd "(sed -i.bak s/ENABLED=0/ENABLED=1/g $ST_DEFAULT)"

    log "[install_stunnel] Starting stunnel main daemon..."
    run_cmd "(systemctl start stunnel4.service)"
}

fix_hostname()
{
  log "Fixing hostname in /etc/hosts..."
  
  set +e
  (
    grep -q "${HOSTNAME}" /etc/hosts

  if [ $? == 0 ]; then
    log "Hostname ${HOSTNAME} already exists in /etc/hosts"
  else
    log "$Appending {HOSTNAME} to /etc/hosts"
    run_cmd "(echo \"127.0.0.1 ${HOSTNAME}\" >> /etc/hosts)"
  fi
  )
  set -e
}

#########################
# Check requirements
#########################

if [ "${UID}" -ne 0 ]; then
    echo "Script executed without root permissions"
    echo "You must be root to run this program." >&2
    exit 3
fi


#########################
# Main
#########################

log "Logstash extension script started @${HOSTNAME}"
START_TIME=$SECONDS

export DEBIAN_FRONTEND=noninteractive


#########################
# Parameter handling
#########################

#Loop through options passed
while getopts :V:L:U:R:P:W:K:h optname; do
  log "Option $optname set to '${OPTARG}'"
  case $optname in
    V) #Logstash version number
      LOGSTASH_VERSION=${OPTARG}
      ;;
    L) #install additional plugins
      INSTALL_ADDITIONAL_PLUGINS="${OPTARG}"
      ;;
    U) #install additional plugins
      ES_URI="${OPTARG}"
      ;;
    R) #Redis host
      REDIS_HOST="${OPTARG}"
      ;;
    P) #Redis port
      REDIS_PORT="${OPTARG}"
      ;;
    W) #Redis password
      REDIS_PASSWORD="${OPTARG}"
      ;;      
    K) #Redis list/channel
      REDIS_KEY="${OPTARG}"
      ;;
    h) #show help
      help
      exit 2
      ;;
    \?) #unrecognized option - show help
      echo -e \\n"Option -$OPTARG$ not allowed."
      help
      exit 2
      ;;
  esac
done


log "Bootstrapping Logstash..."

#########################
# Installation sequence
#########################

fix_hostname

install_monit

install_stunnel

install_java

install_logstash

# install additional plugins for logstash if necessary
if [[ ! -z "${INSTALL_ADDITIONAL_PLUGINS// }" ]]; then
    install_additional_plugins
fi

configure_logstash

configure_monit_stunnel

configure_monit_logstash

ELAPSED_TIME=$(($SECONDS - $START_TIME))
PRETTY=$(printf '%dh:%dm:%ds\n' $(($ELAPSED_TIME/3600)) $(($ELAPSED_TIME%3600/60)) $(($ELAPSED_TIME%60)))

log "Logstash extension script ended @${HOSTNAME} in ${PRETTY}"
exit 0
