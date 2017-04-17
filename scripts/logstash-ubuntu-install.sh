#!/bin/bash

# License: https://github.com/elastic/azure-marketplace/blob/master/LICENSE.txt
#
# Trent Swanson (Full Scale 180 Inc)
# Martijn Laarman, Greg Marzouka, Russ Cam (Elastic)
# Contributors
#

#########################
# HELP
#########################

help()
{
    echo "This script installs Elasticsearch cluster on Ubuntu"
    echo "Parameters:"
    echo "-n elasticsearch cluster name"
    echo "-v elasticsearch version 1.5.0"
    echo "-p hostname prefix of nodes for unicast discovery"

    echo "-d cluster uses dedicated masters"
    echo "-Z <number of nodes> hint to the install script how many data nodes we are provisioning"

    echo "-A admin password"
    echo "-R read password"
    echo "-K kibana user password"
    echo "-S kibana server password"
    echo "-X enable anonymous access with monitoring role (for health probes)"

    echo "-x configure as a dedicated master node"
    echo "-y configure as client only node (no master, no data)"
    echo "-z configure as data node (no master)"
    echo "-l install plugins"
    echo "-L <plugin;plugin> install additional plugins"

    echo "-j install azure cloud plugin for snapshot and restore"
    echo "-a set the default storage account for azure cloud plugin"
    echo "-k set the key for the default storage account for azure cloud plugin"

    echo "-h view this help content"
}
# Custom logging with time so we can easily relate running times, also log to separate file so order is guaranteed.
# The Script extension output the stdout/err buffer in intervals with duplicates.
log()
{
    echo \[$(date +%d%m%Y-%H:%M:%S)\] "$1"
    echo \[$(date +%d%m%Y-%H:%M:%S)\] "$1" >> /var/log/arm-install.log
}

log "Begin execution of Elasticsearch script extension on ${HOSTNAME}"
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

CLUSTER_NAME="elasticsearch"
NAMESPACE_PREFIX=""
ES_VERSION="2.0.0"
INSTALL_PLUGINS=0
INSTALL_ADDITIONAL_PLUGINS=""
CLIENT_ONLY_NODE=0
DATA_ONLY_NODE=0
MASTER_ONLY_NODE=0

CLUSTER_USES_DEDICATED_MASTERS=0
DATANODE_COUNT=0

MINIMUM_MASTER_NODES=3
UNICAST_HOSTS='["'"$NAMESPACE_PREFIX"'master-0:9300","'"$NAMESPACE_PREFIX"'master-1:9300","'"$NAMESPACE_PREFIX"'master-2:9300"]'

USER_ADMIN_PWD="changeME"
USER_READ_PWD="changeME"
USER_KIBANA4_PWD="changeME"
USER_KIBANA4_SERVER_PWD="changeME"
ANONYMOUS_ACCESS=0

INSTALL_AZURECLOUD_PLUGIN=0
STORAGE_ACCOUNT=""
STORAGE_KEY=""

#Loop through options passed
while getopts :n:v:A:R:K:S:Z:p:a:k:L:Xxyzldjh optname; do
  log "Option $optname set"
  case $optname in
    n) #set cluster name
      CLUSTER_NAME=${OPTARG}
      ;;
    v) #elasticsearch version number
      ES_VERSION=${OPTARG}
      ;;
    A) #security admin pwd
      USER_ADMIN_PWD=${OPTARG}
      ;;
    R) #security readonly pwd
      USER_READ_PWD=${OPTARG}
      ;;
    K) #security kibana user pwd
      USER_KIBANA4_PWD=${OPTARG}
      ;;
    S) #security kibana server pwd
      USER_KIBANA4_SERVER_PWD=${OPTARG}
      ;;
    X) #anonymous access
      ANONYMOUS_ACCESS=1
      ;;
    Z) #number of data nodes hints (used to calculate minimum master nodes)
      DATANODE_COUNT=${OPTARG}
      ;;
    x) #master node
      MASTER_ONLY_NODE=1
      ;;
    y) #client node
      CLIENT_ONLY_NODE=1
      ;;
    z) #data node
      DATA_ONLY_NODE=1
      ;;
    l) #install plugins
      INSTALL_PLUGINS=1
      ;;
    L) #install additional plugins
      INSTALL_ADDITIONAL_PLUGINS="${OPTARG}"
      ;;
    d) #cluster is using dedicated master nodes
      CLUSTER_USES_DEDICATED_MASTERS=1
      ;;
    p) #namespace prefix for nodes
      NAMESPACE_PREFIX="${OPTARG}"
      ;;
    j) #install azure cloud plugin
      INSTALL_AZURECLOUD_PLUGIN=1
      ;;
    a) #azure storage account for azure cloud plugin
      STORAGE_ACCOUNT=${OPTARG}
      ;;
    k) #azure storage account key for azure cloud plugin
      STORAGE_KEY=${OPTARG}
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

#########################
# Parameter state changes
#########################

if [ ${CLUSTER_USES_DEDICATED_MASTERS} -ne 0 ]; then
    MINIMUM_MASTER_NODES=2
    UNICAST_HOSTS='["'"$NAMESPACE_PREFIX"'master-0:9300","'"$NAMESPACE_PREFIX"'master-1:9300","'"$NAMESPACE_PREFIX"'master-2:9300"]'
else
    MINIMUM_MASTER_NODES=$(((DATANODE_COUNT/2)+1))
    UNICAST_HOSTS='['
    for i in $(seq 0 $((DATANODE_COUNT-1))); do
        UNICAST_HOSTS="$UNICAST_HOSTS\"${NAMESPACE_PREFIX}data-$i:9300\","
    done
    UNICAST_HOSTS="${UNICAST_HOSTS%?}]"
fi

log "Bootstrapping an Elasticsearch $ES_VERSION cluster named '$CLUSTER_NAME' with minimum_master_nodes set to $MINIMUM_MASTER_NODES"
log "Cluster uses dedicated master nodes is set to $CLUSTER_USES_DEDICATED_MASTERS and unicast goes to $UNICAST_HOSTS"
log "Cluster install plugins is set to $INSTALL_PLUGINS"


#########################
# Installation steps as functions
#########################

# Format data disks (Find data disks then partition, format, and mount them as seperate drives)
format_data_disks()
{
    log "[format_data_disks] starting to RAID0 the attached disks"
    # using the -s paramater causing disks under /datadisks/* to be raid0'ed
    bash vm-disk-utils-0.1.sh -s
    log "[format_data_disks] finished RAID0'ing the attached disks"
}

# Configure Elasticsearch Data Disk Folder and Permissions
setup_data_disk()
{
    local RAIDDISK="/datadisks/disk1"
    log "[setup_data_disk] Configuring disk $RAIDDISK/elasticsearch/data"
    mkdir -p "$RAIDDISK/elasticsearch/data"
    chown -R elasticsearch:elasticsearch "$RAIDDISK/elasticsearch"
    chmod 755 "$RAIDDISK/elasticsearch"
}

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

    #if the previus did not install correctly we go nuclear, otherwise this loop will early exit
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

# Install Elasticsearch
install_es()
{
    if [[ "${ES_VERSION}" == \2* ]]; then
        DOWNLOAD_URL="https://download.elasticsearch.org/elasticsearch/release/org/elasticsearch/distribution/deb/elasticsearch/$ES_VERSION/elasticsearch-$ES_VERSION.deb?ultron=msft&gambit=azure"
    elif [[ "${ES_VERSION}" == \5* ]]; then
        DOWNLOAD_URL="https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-$ES_VERSION.deb?ultron=msft&gambit=azure"
    else
        DOWNLOAD_URL="https://download.elasticsearch.org/elasticsearch/elasticsearch/elasticsearch-$ES_VERSION.deb"
    fi

    log "[install_es] Installing Elasticsearch Version - $ES_VERSION"
    log "[install_es] Download location - $DOWNLOAD_URL"
    sudo wget -q "$DOWNLOAD_URL" -O elasticsearch.deb
    log "[install_es] Downloaded elasticsearch $ES_VERSION"
    sudo dpkg -i elasticsearch.deb
    log "[install_es] Installed Elasticsearch Version - $ES_VERSION"

    log "[install_es] Disable Elasticsearch System-V style init scripts (will be using monit)"
    sudo update-rc.d elasticsearch disable
}

## Plugins
##----------------------------------

plugin_cmd()
{
    if [[ "${ES_VERSION}" == \5* ]]; then
      echo /usr/share/elasticsearch/bin/elasticsearch-plugin
    else
      echo /usr/share/elasticsearch/bin/plugin
    fi
}

install_plugins()
{
    if [[ "${ES_VERSION}" == \5* ]]; then
      sudo $(plugin_cmd) install x-pack --batch
    else
      log "[install_plugins] Installing X-Pack plugins security, Marvel, Watcher"
      sudo $(plugin_cmd) install license
      sudo $(plugin_cmd) install shield
      sudo $(plugin_cmd) install watcher
      sudo $(plugin_cmd) install marvel-agent
      if dpkg --compare-versions "$ES_VERSION" ">=" "2.3.0"; then
        log "[install_plugins] Installing X-Pack plugin Graph"
        sudo $(plugin_cmd) install graph
        log "[install_plugins] Installed X-Pack plugin Graph"
      fi
      log "[install_plugins] Installed X-Pack plugins security, Marvel, Watcher"
    fi

}

install_azure_cloud_plugin()
{
    log "[install_azure_cloud_plugin] Installing plugin Cloud-Azure"
    if [[ "${ES_VERSION}" == \5* ]]; then
    	sudo $(plugin_cmd) install repository-azure
    else
    	sudo $(plugin_cmd) install cloud-azure
    fi
    log "[install_azure_cloud_plugin] Installed plugin Cloud-Azure"
}

install_additional_plugins()
{
    SKIP_PLUGINS="license shield watcher marvel-agent graph cloud-azure"
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

## Security
##----------------------------------

security_cmd()
{
    if [[ "${ES_VERSION}" == \5* ]]; then
      echo /usr/share/elasticsearch/bin/x-pack/users
    else
      echo /usr/share/elasticsearch/bin/shield/esusers
    fi
}

apply_security_settings_2x()
{
    local SEC_FILE=/etc/elasticsearch/shield/roles.yml
    log "[apply_security_settings]  Check that $SEC_FILE contains kibana4 role"
    if ! sudo grep -q "kibana4:" "$SEC_FILE"; then
        log "[apply_security_settings]  No kibana4 role. Adding now"
        {
            echo -e ""
            echo -e "# kibana4 user role."
            echo -e "kibana4:"
            echo -e "  cluster:"
            echo -e "    - monitor"
            echo -e "  indices:"
            echo -e "    - names: '*'"
            echo -e "      privileges:"
            echo -e "        - view_index_metadata"
            echo -e "        - read"
            echo -e "    - names: '.kibana*'"
            echo -e "      privileges:"
            echo -e "        - manage"
            echo -e "        - read"
            echo -e "        - index"
        } >> $SEC_FILE
        log "[apply_security_settings]  kibana4 role added"
    fi
    log "[apply_security_settings]  Finished checking roles.yml for kibana4 role"

    if [ ${ANONYMOUS_ACCESS} -ne 0 ]; then
      log "[apply_security_settings]  Check that $SEC_FILE contains anonymous_user role"
      if ! sudo grep -q "anonymous_user:" "$SEC_FILE"; then
          log "[apply_security_settings]  No anonymous_user role. Adding now"
          {
              echo -e ""
              echo -e "# anonymous user role."
              echo -e "anonymous_user:"
              echo -e "  cluster:"
              echo -e "    - cluster:monitor/main"
          } >> $SEC_FILE
          log "[apply_security_settings]  anonymous_user role added"
      fi
      log "[apply_security_settings]  Finished checking roles.yml for anonymous_user role"
    fi

    log "[apply_security_settings] Start adding es_admin"
    sudo $(security_cmd) useradd "es_admin" -p "${USER_ADMIN_PWD}" -r admin
    log "[instalapply_security_settingsl_plugins] Finished adding es_admin"

    log "[apply_security_settings]  Start adding es_read"
    sudo $(security_cmd) useradd "es_read" -p "${USER_READ_PWD}" -r user
    log "[apply_security_settings]  Finished adding es_read"

    log "[apply_security_settings]  Start adding es_kibana"
    sudo $(security_cmd) useradd "es_kibana" -p "${USER_KIBANA4_PWD}" -r kibana4
    log "[apply_security_settings]  Finished adding es_kibana"

    log "[apply_security_settings]  Start adding es_kibana_server"
    sudo $(security_cmd) useradd "es_kibana_server" -p "${USER_KIBANA4_SERVER_PWD}" -r kibana4_server
    log "[apply_security_settings]  Finished adding es_kibana_server"
}

node_is_up()
{
  curl --output /dev/null --silent --head --fail http://localhost:9200 --user elastic:$1
  return $?
}
wait_for_started()
{
  for i in $(seq 30); do
    if $(node_is_up "changeme" || node_is_up "$USER_ADMIN_PWD"); then
      log "[wait_for_started] Node is up!"
      return
    else
      sleep 5
      log "[wait_for_started] Seeing if node is up for the after sleeping 5 seconds, retry ${i}/30"
    fi
  done
  log "[wait_for_started] never saw elasticsearch go up locally"
  exit 10
}


## Configuration
##----------------------------------

configure_logstash_yml()
{
    # Backup the current logstash configuration file
    mv /etc/logstash/logstash.yml /etc/logstash/logstash.bak

    # Set cluster and machine names - just use hostname for our node.name
    echo "cluster.name: $CLUSTER_NAME" >> /etc/logstash/logstash.yml
    echo "node.name: ${HOSTNAME}" >> /etc/logstash/logstash.yml

    log "[configure_elasticsearch_yaml] Update configuration with data path list of $DATAPATH_CONFIG"
    echo "path.data: /datadisks/disk1/elasticsearch/data" >> /etc/logstash/logstash.yml

    # Configure discovery
    log "[configure_elasticsearch_yaml] Update configuration with hosts configuration of $UNICAST_HOSTS"
    echo "discovery.zen.ping.unicast.hosts: $UNICAST_HOSTS" >> /etc/logstash/logstash.yml

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
    echo "set daemon 30" >> /etc/monit/monitrc
    echo "set httpd port 2812 and" >> /etc/monit/monitrc
    echo "    use address localhost" >> /etc/monit/monitrc
    echo "    allow localhost" >> /etc/monit/monitrc
    sudo touch /etc/monit/conf.d/logstash.conf
    echo "check process logstash with pidfile \"/var/run/logstash/logstash.pid\"" >> /etc/monit/conf.d/logstash.conf
    echo "  group logstash" >> /etc/monit/conf.d/logstash.conf
    echo "  start program = \"/etc/init.d/logstash start\"" >> /etc/monit/conf.d/logstash.conf
    echo "  stop program = \"/etc/init.d/logstash stop\"" >> /etc/monit/conf.d/logstash.conf
    log "[install_monit] installed monit"
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

  # restart elasticsearch if the configuration has changed
  cmp --silent /etc/logstash/logstash.yml /etc/logstash/logstash.bak \
    || sudo monit restart logstash

  exit 0
fi
install_ntp

install_java

install_logstash

install_monit

configure_logstash_yml

start_monit

ELAPSED_TIME=$(($SECONDS - $START_TIME))
PRETTY=$(printf '%dh:%dm:%ds\n' $(($ELAPSED_TIME/3600)) $(($ELAPSED_TIME%3600/60)) $(($ELAPSED_TIME%60)))

log "End execution of Elasticsearch script extension on ${HOSTNAME} in ${PRETTY}"
exit 0
