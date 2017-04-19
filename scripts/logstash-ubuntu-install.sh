#!/bin/bash

#########################
# HELP
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
    echo \[$(date +%d%m%Y-%H:%M:%S)\] "$1"
    echo \[$(date +%d%m%Y-%H:%M:%S)\] "$1" >> /var/log/arm-install.log
}

log "Begin execution of Logstash script extension on ${HOSTNAME}"
START_TIME=$SECONDS

export DEBIAN_FRONTEND=noninteractive

#########################
# Preconditions
#########################

if [ "${UID}" -ne 0 ];
then
    log "Script executed without root permissions"
    echo "You must be root to run this program." >&2
    exit 3
fi

# TEMP FIX - Re-evaluate and remove when possible
# This is an interim fix for hostname resolution in current VM
grep -q "${HOSTNAME}" /etc/hosts
if [ $? == 0 ]
then
  log "${HOSTNAME}found in /etc/hosts"
else
  log "${HOSTNAME} not found in /etc/hosts"
  # Append it to the hsots file if not there
  echo "127.0.0.1 ${HOSTNAME}" >> /etc/hosts
  log "hostname ${HOSTNAME} added to /etchosts"
fi

#########################
# Parameter handling
#########################

LOGSTASH_VERSION="5.3.0"
INSTALL_ADDITIONAL_PLUGINS=""
ES_URI="http://10.0.0.4:9200"
REDIS_HOST="some.domain.com"
REDIS_PORT="6380"
REDIS_PASSWORD="ChangeMe"
REDIS_KEY="logstash"

#Loop through options passed
while getopts :V:L:U:R:P:W:K:h optname; do
  log "Option $optname set"
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
    K) #Redis list/channel
      REDIS_KEY="${OPTARG}"
      ;;
    h) #show help
      help
      exit 2
      ;;
    \?) #unrecognized option - show help
      echo -e \\n"Option -${BOLD}$OPTARG${NORM} not allowed."
      help
      exit 2
      ;;
  esac
done

log "Bootstrapping Logstash $LOGSTASH_VERSION"


#########################
# Installation steps as functions
#########################

# Install Oracle Java
install_java()
{
    log "[install_java] Adding apt repository for java 8"
    (add-apt-repository -y ppa:webupd8team/java || (sleep 15; add-apt-repository -y ppa:webupd8team/java))
    log "[install_java] updating apt-get"

    (apt-get -y update || (sleep 15; apt-get -y update)) > /dev/null
    log "[install_java] updated apt-get"
    echo debconf shared/accepted-oracle-license-v1-1 select true | sudo debconf-set-selections
    echo debconf shared/accepted-oracle-license-v1-1 seen true | sudo debconf-set-selections
    log "[install_java] Installing Java"
    (apt-get -yq install oracle-java8-installer || (sleep 15; apt-get -yq install oracle-java8-installer))
    command -v java >/dev/null 2>&1 || { sleep 15; sudo rm /var/cache/oracle-jdk8-installer/jdk-*; sudo apt-get install -f; }

    #if the previous did not install correctly we go nuclear, otherwise this loop will early exit
    for i in $(seq 30); do
      if $(command -v java >/dev/null 2>&1); then
        log "[install_java] Installed java!"
        return
      else
        sleep 5
        sudo rm /var/cache/oracle-jdk8-installer/jdk-*;
        sudo rm -f /var/lib/dpkg/info/oracle-java8-installer*
        sudo rm /etc/apt/sources.list.d/*java*
        sudo apt-get -yq purge oracle-java8-installer*
        sudo apt-get -yq autoremove
        sudo apt-get -yq clean
        (add-apt-repository -y ppa:webupd8team/java || (sleep 15; add-apt-repository -y ppa:webupd8team/java))
        sudo apt-get -yq update
        sudo apt-get -yq install --reinstall oracle-java8-installer
        log "[install_java] Seeing if java is Installed after nuclear retry ${i}/30"
      fi
    done
    command -v java >/dev/null 2>&1 || { log "Java did not get installed properly even after a retry and a forced installation" >&2; exit 50; }
}

# Install Logstash
install_logstash()
{
    if [[ "${LOGSTASH_VERSION}" == \2* ]]; then
        DOWNLOAD_URL="https://download.elastic.co/logstash/logstash/packages/debian/logstash-$LOGSTASH_VERSION_all.deb"
    elif [[ "${LOGSTASH_VERSION}" == \5* ]]; then
        DOWNLOAD_URL="https://artifacts.elastic.co/downloads/logstash/logstash-$LOGSTASH_VERSION.deb"
    else
        DOWNLOAD_URL="https://artifacts.elastic.co/downloads/logstash/logstash-$LOGSTASH_VERSION.deb"
    fi

    log "[install_logstash] Installing logstash version - $LOGSTASH_VERSION"
    log "[install_logstash] Download location - $DOWNLOAD_URL"
    sudo wget -q "$DOWNLOAD_URL" -O logstash.deb
    log "[install_logstash] Downloaded logstash $LOGSTASH_VERSION"
    sudo dpkg -i logstash.deb
    log "[install_logstash] Installed logstash version - $LOGSTASH_VERSION"

    log "[install_logstash] Disable logstash System-V style init scripts (will be using monit)"
    sudo update-rc.d logstash disable
}

## Plugins
##----------------------------------

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
    SKIP_PLUGINS="license"
    log "[install_additional_plugins] Installing additional plugins"
    for PLUGIN in $(echo $INSTALL_ADDITIONAL_PLUGINS | tr ";" "\n")
    do
        if [[ $SKIP_PLUGINS =~ $PLUGIN ]]; then
            log "[install_additional_plugins] Skipping plugin $PLUGIN"
        else
            log "[install_additional_plugins] Installing plugin $PLUGIN"
            sudo $(plugin_cmd) install $PLUGIN
            log "[install_additional_plugins] Installed plugin $PLUGIN"
        fi
    done
}


## Configuration
##----------------------------------

configure_logstash_yml()
{

    local LOGSTASH_CONF=/etc/logstash/logstash.yml

    log "[configure_logstash_yml] Configuring Logstash $LOGSTASH_CONF"

    log "[configure_logstash_yml] Backup old $LOGSTASH_CONF"
    mv $LOGSTASH_CONF $LOGSTASH_CONF.bak

    log "[configure_logstash_yml] Pointing output to $ES_URI"
    if [[ "${ES_VERSION}" == \5* ]]; then
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
          echo -e ""
          echo -e "# output to Elasticsearch cluster"
          echo -e "output {"
          echo -e "  elasticsearch { hosts => [\"$ES_URI\"] }"
          echo -e "}"
          echo -e ""
      } >> $LOGSTASH_CONF
    fi 
}




## Installation of dependencies
##----------------------------------

install_ntp()
{
    log "[install_ntp] installing ntp daemon"
    (apt-get -yq install ntp || (sleep 15; apt-get -yq install ntp))
    ntpdate pool.ntp.org
    log "[install_ntp] installed ntp daemon and ntpdate"
}

install_monit()
{
    log "[install_monit] installing monit"
    (apt-get -yq install monit || (sleep 15; apt-get -yq install monit))
    log "[install_monit] installed monit"

    local MONIT_CONF=/etc/monit/monitrc
    log "[install_monit] Appending Monit $MONIT_CONF"
    echo "set daemon 30" >> $MONIT_CONF
    echo "set httpd port 2812 and" >> $MONIT_CONF
    echo "    use address localhost" >> $MONIT_CONF
    echo "    allow localhost" >> $MONIT_CONF

    local MONIT_LS_CONF=/etc/monit/conf.d/logstash.conf
    log "[install_monit] Creating Monit config for Logstash $MONIT_LS_CONF"
    sudo touch $MONIT_LS_CONF
    echo "check process logstash with pidfile \"/var/run/logstash/logstash.pid\"" >> $MONIT_LS_CONF
    echo "  group logstash" >> $MONIT_LS_CONF
    echo "  start program = \"/etc/init.d/logstash start\"" >> $MONIT_LS_CONF
    echo "  stop program = \"/etc/init.d/logstash stop\"" >> $MONIT_LS_CONF
    log "[install_monit] configured monit"
}

start_monit()
{
    log "[start_monit] starting monit"
    sudo /etc/init.d/monit start
    sudo monit reload # use the new configuration
    sudo monit start all
    log "[start_monit] started monit"
}


#########################
# Installation sequence
#########################


# if elasticsearch is already installed assume this is a redeploy
# change yaml configuration and only restart the server when needed
if sudo monit status logstash >& /dev/null; then

  configure_logstash_yml

  # restart logstash if the configuration has changed
  cmp --silent /etc/logstash/logstash.yml /etc/logstash/logstash.bak \
    || sudo monit restart logstash

  exit 0
fi
install_ntp

install_java

install_logstash

if [[ ! -z "${INSTALL_ADDITIONAL_PLUGINS// }" ]]; then
    install_additional_plugins
fi

install_monit

configure_logstash_yml

start_monit

ELAPSED_TIME=$(($SECONDS - $START_TIME))
PRETTY=$(printf '%dh:%dm:%ds\n' $(($ELAPSED_TIME/3600)) $(($ELAPSED_TIME%3600/60)) $(($ELAPSED_TIME%60)))

log "End execution of Logstash script extension on ${HOSTNAME} in ${PRETTY}"
exit 0
