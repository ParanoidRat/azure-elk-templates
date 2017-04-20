#!/bin/bash
# see http://redsymbol.net/articles/unofficial-bash-strict-mode/
# for explanation of set options
set -euo pipefail
IFS=$'\n\t'

#########################
# Global vars
#########################
DEBUG=1

# Console output text colors
BOLD=$(tput bold)
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
NORMAL=$(tput sgr0)

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
    echo "-K <key> Redis list or channel name for Logstash to read inputs (e.g. logstash)"
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
      if [ $DEBUG ]; then log "[run_cmd]${GREEN}[+] $@ ${NORMAL}"; fi  
    else
      log "[run_cmd] [run_cmd]${BOLD}${RED}[!] $@ ${NORMAL}"
    fi
  )
  # re-enable the exit-immediately-on-error option
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
    local LOGSTASH_CONF=/etc/logstash/conf.d/100.redis.conf

    log "[configure_logstash] Logstash configuration started..."

    log "[configure_logstash] Backup old $LOGSTASH_CONF"
    mv $LOGSTASH_CONF $LOGSTASH_CONF.bak

    log "[configure_logstash] Redis input defined as '$REDIS_HOST:$REDIS_PORT'"
    log "[configure_logstash] Redis channel defined as '$REDIS_KEY'"
    log "[configure_logstash] Elasticsearch output URI defined as '$ES_URI'"

    if [[ "${LOGSTASH_VERSION}" == \5* ]]; then
      {
          echo -e "# Get input from Redis bufffer"
          echo -e "input {"
          echo -e "  redis {"
          echo -e "    host => \"$REDIS_HOST\""
          echo -e "    port => \"$REDIS_PORT\""
          echo -e "    password => \"$REDIS_PASSWORD\""
          echo -e "    data_type => \"channel\""
          echo -e "    key => \"$REDIS_KEY\""
          echo -e "  }"
          echo -e "}"
          echo -e ""
          echo -e "# Send output to Elasticsearch cluster"
          echo -e "output {"
          echo -e "  elasticsearch { hosts => [\"$ES_URI\"] }"
          echo -e "}"
          echo -e ""
      } >> $LOGSTASH_CONF
    else
      {
          echo -e "# Get input from Redis bufffer"
          echo -e "input {"
          echo -e "  redis {"
          echo -e "    host => \"$REDIS_HOST\""
          echo -e "    port => \"$REDIS_PORT\""
          echo -e "    password => \"$REDIS_PASSWORD\""
          echo -e "    data_type => \"channel\""
          echo -e "    key => \"$REDIS_KEY\""
          echo -e "  }"
          echo -e "}"
          echo -e ""
          echo -e "# Send output to Elasticsearch cluster"
          echo -e "output {"
          echo -e "  elasticsearch { hosts => [\"$ES_URI\"] }"
          echo -e "}"
          echo -e ""
      } >> $LOGSTASH_CONF
    fi 
}

configure_logstash_monit()
{
    local MONIT_LS_CONF=/etc/monit/conf.d/logstash.conf
    
    log "[configure_logstash_monit] Generating Logstash config for Monit @ $MONIT_LS_CONF"
    run_cmd "(touch $MONIT_LS_CONF)"
    {
      echo -e "check process logstash matching \"logstash/runner.rb\""
      echo -e "  group logstash"
      echo -e "  start program = \"/bin/systemctl start logstash.service\""
      echo -e "  stop program = \"/bin/systemctl start logstash.service\""
    } > $MONIT_LS_CONF      

    log "[configure_logstash_monit] Reloading Monit and starting services..."
    run_cmd "(monit reload)"
    run_cmd "(monit start all)"
}

install_monit()
{
    local MONIT_CONF=/etc/monit/monitrc


    log "[install_monit] Monit install started..."
    run_cmd "(apt-get -yq install monit || (sleep 15; apt-get -yq install monit))"
    
    log "[install_monit] Appending Monit configuration @ $MONIT_CONF ..."
    {
      echo -e "set daemon 30"
      echo -e "set httpd port 2812 and"
      echo -e "    use address localhost"
      echo -e "    allow localhost" 
    } >> $MONIT_CONF

    

    log "[install_monit] Starting monit..."
    run_cmd "(systemctl start monit.service)"

}

fix_hostname()
{
  log "Fixing hostname in /etc/hosts..."
  
  set -e
  (
    grep -q "${HOSTNAME}" /etc/hosts
  )

  if [ $? == 0 ]; then
    log "${HOSTNAME} found in /etc/hosts"
  else
    log "${HOSTNAME} not found in /etc/hosts"
    # Append it to the hsots file if not there
    run_cmd "(echo \"127.0.0.1 ${HOSTNAME}\" >> /etc/hosts)"
    log "hostname ${HOSTNAME} added to /etc/hosts"
  fi
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
      echo -e \\n"Option -${BOLD}$OPTARG${NORMAL} not allowed."
      help
      exit 2
      ;;
  esac
done


log "Bootstrapping Logstash..."

#########################
# Installation sequence
#########################


# if logstash is already installed assume this is a redeploy
# change yaml configuration and only restart the server when needed
if monit status logstash >& /dev/null; then
  configure_logstash

  # restart logstash if the configuration has changed
  cmp --silent /etc/logstash/logstash.yml /etc/logstash/logstash.bak \
    || monit restart logstash

  exit 0
fi

fix_hostname

install_monit

install_java

install_logstash

# install additional plugins for logstash if necessary
if [[ ! -z "${INSTALL_ADDITIONAL_PLUGINS// }" ]]; then
    install_additional_plugins
fi

configure_logstash

# Logstash started by SystemD (Ubuntu 16.04) does not record main Java process PID.
# As such, Monit could not reliably monitor it
#configure_logstash_monit

ELAPSED_TIME=$(($SECONDS - $START_TIME))
PRETTY=$(printf '%dh:%dm:%ds\n' $(($ELAPSED_TIME/3600)) $(($ELAPSED_TIME%3600/60)) $(($ELAPSED_TIME%60)))

log "Logstash extension script ended @${HOSTNAME} in ${PRETTY}"
exit 0
