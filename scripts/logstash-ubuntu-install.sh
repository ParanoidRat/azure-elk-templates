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
    if [ $DEBUG ]; then
      echo \[$(date '+%Y-%m-%d %H:%M:%S')\] "$1" 
    else
      echo \[$(date '+%Y-%m-%d %H:%M:%S')\] "$1" >> /var/log/arm-install.log
    fi
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

check_start_restart_service()
{
    local RETRY_T="5"
    local RETRY_N="3"

    log "[check_start_restart_service_$@] Checking for running service '$@' ..."
    set +e
    (
      if $(systemctl is-active $@.service >/dev/null); then
        log "[check_start_restart_service_$@]   Service '$@' already running. Restarting..."
        if $(systemctl restart $@.service; sleep $RETRY_T; systemctl is-active $@.service >/dev/null); then
          log "[check_start_restart_service_$@]   Service '$@' restarted successfully"
        else
          log "[check_start_restart_service_$@]   Something went wrong when restarting service '$@'. Moving on..."
        fi
      else
        for i in $(seq $RETRY_N); do
            log "[check_start_restart_service_$@]   Attempt ${i}/$RETRY_N to start '$@'"
            if $(systemctl start $@.service; sleep $RETRY_T; systemctl is-active $@.service >/dev/null); then
              log "[check_start_restart_service_$@]   Service '$@' started successfully"
              return
            else
              log "[check_start_restart_service_$@]   Something is wrong... Pausing for $RETRY_T sec"
              sleep $RETRY_T
            fi
        done
      fi
    )
    set -e
}

check_create_conf()
{
    log "[check_create_conf] Checking for old version of $@ ..."
    set +e
    (
      if [[ -f "$@" ]]; then
        log "[check_create_conf]   $@ already present, backing up..."
        run_cmd "(mv $@ $@-$(date '+%Y%m%d%H%M%S').bak)"
      else
        log "[check_create_conf]   $@ does not exist"
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
    local LS_CONF_SYSLOG=/etc/logstash/conf.d/020-syslog-filter.conf
    local LS_CONF_DHCPD=/etc/logstash/conf.d/030-dhcpd-filter.conf    
    local LS_CONF_ES=/etc/logstash/conf.d/040-elastic-output.conf
    
    local LS_GROK_DIR=/etc/logstash/patterns.d
  

    log "[configure_logstash] Logstash configuration started..."

    log "[configure_logstash] Generating $LS_CONF_R..."
    log "[configure_logstash] Redis defined as '$REDIS_HOST:$REDIS_PORT'"
    log "[configure_logstash] Redis channel defined as '$REDIS_KEY'"
    set +e
    (
      cat <<-EOF > $LS_CONF_R
        input {
          redis {
            host => "localhost"
            port => "6379"
            password => "$REDIS_PASSWORD"

            key => "$REDIS_KEY"
            data_type => "list"

            threads => 8
            codec => "json"

            add_field => { "indexed_by" => "${HOSTNAME}" }
          }
        }
EOF
    )
    set -e

    log "[configure_logstash] Generating $LS_CONF_ES..."
    log "[configure_logstash] Elasticsearch output URI defined as '$ES_URI'"
    set +e
    (
      cat <<-EOF > $LS_CONF_ES
        output {
          elasticsearch {
            hosts => [ "$ES_URI" ]
            manage_template => false
            index => "%{[src_id]}-%{[log_type]}-%{+YYYY.MM.dd}"
            document_type => "%{[log_type]}"
          }
        }
EOF
    )
    set -e

    log "[configure_logstash] Generating $LS_CONF_SYSLOG..."
    set +e
    (
      cat <<-EOF > $LS_CONF_SYSLOG
      filter {
        if [type] == "syslog" {
          grok {
            match => { "message" => "%{SYSLOGBASE} %{GREEDYDATA:message}" }
            overwrite => [ "message" ]

            add_field => [ "received_at", "%{@timestamp}" ]

            add_tag        => [ "_grok_success_syslog" ]
            tag_on_failure => [ "_grok_nomatch_syslog" ]
          }
          date {
            match => [ "timestamp", "MMM  d HH:mm:ss", "MMM dd HH:mm:ss" ]
            timezone => "US/Eastern"
            target => "@timestamp"
          }
        }
      }
EOF
    )
    set -e


    log "[configure_logstash] Generating $LS_CONF_DHCPD..."
    set +e
    (
      cat <<-EOF > $LS_CONF_DHCPD
      filter {
        if [log_type] == "dhcp" {
          grok {
            patterns_dir => [ "$LS_GROK_DIR" ]

            match => { "message" => "%{DHCPD}" }

            add_tag        => [ "_grok_success_dhcpd" ]
            tag_on_failure => [ "_grok_nomatch_dhcpd" ]
          }
        }
      }
EOF
    )
    set -e


    log "[configure_logstash] Making dir $LS_GROK_DIR..."
    run_cmd "(mkdir $LS_GROK_DIR)"

    log "[configure_logstash] Generating DHCPD grok pattern config..."
    set +e
    (
      cat <<-EOF > $LS_GROK_DIR/dhcpd.grok
      DHCPD_VIA via (%{IP:dhcp_relay_ip}|(?<dhcp_device>[^: ]+))

      DHCPD_OPERATION DHCP(%{DHCPD_DISCOVER}|%{DHCPD_OFFER_ACK}|%{DHCPD_REQUEST}|%{DHCPD_DECLINE}|%{DHCPD_RELEASE}|%{DHCPD_INFORM}|%{DHCPD_LEASE})(: %{GREEDYDATA:dhcpd_message})?
      DHCPD_DISCOVER (?<dhcp_operation>DISCOVER) from %{MAC:dhcp_client_mac}( \(%{DATA:dhcp_client_name}\))? %{DHCPD_VIA}
      DHCPD_OFFER_ACK (?<dhcp_operation>(OFFER|N?ACK)) on %{IP:dhcp_client_ip} to %{MAC:dhcp_client_mac}( \(%{DATA:dhcp_client_name}\))? %{DHCPD_VIA}
      DHCPD_REQUEST (?<dhcp_operation>REQUEST) for %{IP:dhcp_client_ip}( \(%{DATA:dhcp_server_ip}\))? from %{MAC:dhcp_client_mac}( \(%{DATA:dhcp_client_name}\))? %{DHCPD_VIA}
      DHCPD_DECLINE (?<dhcp_operation>DECLINE) of %{IP:dhcp_client_ip} from %{MAC:dhcp_client_mac}( \(%{DATA:dhcp_client_name}\))? %{DHCPD_VIA}
      DHCPD_RELEASE (?<dhcp_operation>RELEASE) of %{IP:dhcp_client_ip} from %{MAC:dhcp_client_mac}( \(%{DATA:dhcp_client_name}\))? %{DHCPD_VIA} \((?<dhcpd_release>(not )?found)\)
      DHCPD_INFORM (?<dhcp_operation>INFORM) from %{IP:dhcp_client_ip}? %{DHCPD_VIA}
      DHCPD_LEASE (?<dhcp_operation>LEASE(QUERY|UNKNOWN|ACTIVE|UNASSIGNED)) (from|to) %{IP:dhcp_client_ip} for (IP %{IP:dhcp_leasequery_ip}|client-id %{NOTSPACE:dhcp_leasequery_id}|MAC address %{MAC:dhcp_leasequery_mac})( \(%{NUMBER:dhcp_leasequery_associated} associated IPs\))?

      DHCPD %{DHCPD_OPERATION}
EOF
    )
    set -e    
}

install_monit()
{
    local MONIT_CONF=/etc/monit/monitrc

    log "[install_monit] Installing monit if not present ..."
    check_install_pkg "monit"

    log "[install_monit] Creating $MONIT_CONF if not present ..."
    check_create_conf "$MONIT_CONF"

    log "[install_monit] Generating content for $MONIT_CONF ..."
    run_cmd "(touch $MONIT_CONF && chmod 600 $MONIT_CONF)"
    {
        echo -e "set daemon 120"
        echo -e "  with start delay 60"
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
    check_start_restart_service "monit"
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

    log "[install_stunnel] Installing stunnel4 if not present ..."
    check_install_pkg "stunnel4"

    log "[install_monit] Creating $ST_AZ_REDIS_CONF if not present ..."
    check_create_conf "$ST_AZ_REDIS_CONF"
    
    log "[install_stunnel] Generating content for $ST_AZ_REDIS_CONF ..."
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

    log "[install_stunnel] In-place edit of $ST_DEFAULT enabling tunnels ..."
    run_cmd "(sed -i.bak s/ENABLED=0/ENABLED=1/g $ST_DEFAULT)"

    log "[install_stunnel] Starting stunnel4 if not running ..."
    check_start_restart_service "stunnel4"
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
      log "Appending ${HOSTNAME} to /etc/hosts"
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

log "Logstash extension script started on ${HOSTNAME}"
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

install_stunnel

install_java

install_logstash

# install additional plugins for logstash if necessary
if [[ ! -z "${INSTALL_ADDITIONAL_PLUGINS// }" ]]; then
    install_additional_plugins
fi

configure_logstash

install_monit

configure_monit_logstash

configure_monit_stunnel

ELAPSED_TIME=$(($SECONDS - $START_TIME))
PRETTY=$(printf '%dh:%dm:%ds\n' $(($ELAPSED_TIME/3600)) $(($ELAPSED_TIME%3600/60)) $(($ELAPSED_TIME%60)))

log "Logstash bootstrap script ended on ${HOSTNAME} in ${PRETTY}"
exit 0
