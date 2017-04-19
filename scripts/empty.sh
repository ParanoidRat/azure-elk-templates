#!/bin/bash

#########################
# Global vars
#########################

XYZ="XYZ software"


#########################
# Functions
#########################

help()
{
    echo "This is a do-nothing stub for installation script"
    echo "Parameters:"
    echo "-h view this help content"
}

log()
{
    echo \[$(date '+%Y-%m-%d %H:%M:%S')\] "$1"
    echo \[$(date '+%Y-%m-%d %H:%M:%S')\] "$1" >> /var/log/arm-install.log
}


#########################
# Main
#########################

log "Extension script started @${HOSTNAME}"
START_TIME=$SECONDS

export DEBIAN_FRONTEND=noninteractive

#########################
# Parameter handling
#########################

#Loop through options passed
while getopts :h optname; do
  log "Option $optname set"
  case $optname in
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
# Check requirements
#########################

if [ "${UID}" -ne 0 ];
then
    log "Script executed without root permissions"
    echo "You must be root to run this program." >&2
    exit 3
fi

log "Bootstrapping $XYZ"


ELAPSED_TIME=$(($SECONDS - $START_TIME))
PRETTY=$(printf '%dh:%dm:%ds\n' $(($ELAPSED_TIME/3600)) $(($ELAPSED_TIME%3600/60)) $(($ELAPSED_TIME%60)))

log "Extension script ended @${HOSTNAME} in ${PRETTY}"
exit 0