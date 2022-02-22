#!/bin/bash
################################################################################
# Script:       check_couchdb_replication.sh                                   #
# Author:       Claudio Kuenzler www.claudiokuenzler.com                       #
# Purpose:      Monitor CouchDB replication                                    #
# Licence:      GPLv2                                                          #
# Licence :     GNU General Public Licence (GPL) http://www.gnu.org/           #
# This program is free software; you can redistribute it and/or                #
# modify it under the terms of the GNU General Public License                  #
# as published by the Free Software Foundation; either version 2               #
# of the License, or (at your option) any later version.                       #
#                                                                              #
# This program is distributed in the hope that it will be useful,              #
# but WITHOUT ANY WARRANTY; without even the implied warranty of               #
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the                #
#                                                                              #
# GNU General Public License for more details.                                 #
#                                                                              #
# You should have received a copy of the GNU General Public License            #
# along with this program; if not, write to the Free Software                  #
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA                #
# 02110-1301, USA.                                                             #
#                                                                              #
# (c) 2018, 2022 Claudio Kuenzler                                              #
#                                                                              #
# History:                                                                     #
# 20180105: Created plugin                                                     #
# 20180108: Added -d detection                                                 #
# 20180108: Handle connection problems properly                                #
# 20180326: Input sanitation (either -d or -r are required)                    #
# 20180326: Avoid confusion about wrong credentials (issue 4)                  #
# 20180326: Add possibility to check all replications at once (-r ALL)         #
# 20180326: Handle authentication error "You are not a server admin."          #
# 20220221: Replace jshon with jq                                              #
# 20220221: Improve output of detected replications                            #
# 20220222: Handle "One Time" replications, add -i parameter (issue #5)        #
# 20220222: Improve all HTTP requests with a dedicated function                #
################################################################################
#Variables and defaults
STATE_OK=0              # define the exit code if status is OK
STATE_WARNING=1         # define the exit code if status is Warning
STATE_CRITICAL=2        # define the exit code if status is Critical
STATE_UNKNOWN=3         # define the exit code if status is Unknown
export PATH=$PATH:/usr/local/bin:/usr/bin:/bin # Set path
port=5984
protocol=http
ignore_one_time=true
################################################################################
#Functions
help () {
echo -e "$0  (c) 2018-$(date +%Y) Claudio Kuenzler et al (published under GPL licence)

Usage: ./check_couchdb_replication.sh -H MyCouchDBHost [-P port] [-S] [-u user] [-p pass] (-r replication|-d)

Options:

   * -H Hostname or ip address of CouchDB Host (or Cluster IP)
     -P Port (defaults to 5984)
     -S Use https
     -u Username if authentication is required
     -p Password if authentication is required
  ** -r Replication ID to monitor (doc_id) or use 'ALL' for all replications
  ** -d Dynamically detect and list all available replications
     -i Include 'One time' replications in alerting
     -h Help!

*-H is mandatory for all ways of running the script
**-r is mandatory to check a defined replication (doc_id) 
**-d is mandatory if no replication check (-r) is set

Requirements: curl, jq, tr"
exit $STATE_UNKNOWN;
}

authlogic () {
if [[ -z $user ]] && [[ -z $pass ]]; then echo "COUCHDB REPLICATION UNKNOWN - Authentication required but missing username and password"; exit $STATE_UNKNOWN
elif [[ -n $user ]] && [[ -z $pass ]]; then echo "COUCHDB REPLICATION UNKNOWN - Authentication required but missing password"; exit $STATE_UNKNOWN
elif [[ -n $pass ]] && [[ -z $user ]]; then echo "COUCHDB REPLICATION UNKNOWN - Missing username"; exit $STATE_UNKNOWN
fi
}

httpget() {
  url=$1

  if [[ -n $user && -n $pass ]]
    then authlogic; cdburl="${protocol}://${user}:${pass}@${host}:${port}${url}"
    else cdburl="${protocol}://${host}:${port}${url}"
  fi
  cdbresp=$(curl -k -s $cdburl)

  if [[ -n $(echo $cdbresp | grep -i "Name or password is incorrect") ]]; then
    echo "COUCHDB REPLICATION CRITICAL - Unable to authenticate user $user"
    exit $STATE_CRITICAL
  elif [[ -n $(echo $cdbresp | grep -i "401 Authorization Required") ]]; then
    echo "COUCHDB REPLICATION CRITICAL - Unable to authenticate user $user"
    exit $STATE_CRITICAL
  elif [[ -n $(echo $cdbresp | grep -i "You are not a server admin") ]]; then
    echo "COUCHDB REPLICATION CRITICAL - You are not a server admin"
    exit $STATE_CRITICAL
  elif [[ -n $(echo $cdbresp | grep -i '"error":"not_found"') ]]; then
    echo "COUCHDB REPLICATION CRITICAL - Unable to find replication ($url)"
    exit $STATE_CRITICAL
  elif [[ -z $cdbresp ]]; then
    echo "COUCHDB REPLICATION CRITICAL - Unable to connect to CouchDB on ${protocol}://${host}:${port}"
    exit $STATE_CRITICAL
  fi

}
################################################################################
# Check requirements
for cmd in curl jq tr awk; do
 if ! `which ${cmd} 1>/dev/null`; then
   echo "UNKNOWN: ${cmd} does not exist, please check if command exists and PATH is correct"
   exit ${STATE_UNKNOWN}
 fi
done
################################################################################
# Check for people who need help - aren't we all nice ;-)
if [ "${1}" = "--help" -o "${#}" = "0" ]; then help; exit $STATE_UNKNOWN; fi
################################################################################
# Get user-given variables
while getopts "H:P:Su:p:r:di" Input;
do
  case ${Input} in
  H)      host=${OPTARG};;
  P)      port=${OPTARG};;
  S)      protocol=https;;
  u)      user=${OPTARG};;
  p)      pass=${OPTARG};;
  r)      repid=${OPTARG};;
  d)      detect=1;;
  i)      ignore_one_time=false;;
  *)      help;;
  esac
done

# Check for mandatory opts
if [ -z ${host} ]; then help; exit $STATE_UNKNOWN; fi
if [ -z ${detect} ] && [ -z ${repid} ]; then help; exit $STATE_UNKNOWN; fi
################################################################################
# If -d (detection) is used, present list of replications
if [[ ${detect} -eq 1 ]]; then
  httpget "/_active_tasks"
  replist=$(echo $cdbresp | jq -r '.[] | {doc_id, source} | join (" ")' | while read docid source; do echo "${docid} (${source})"; done | tr "\n" " ")
  if [[ -n $replist ]]; then
    
    echo "COUCHDB AVAILABLE REPLICATIONS: $replist"
    exit $STATE_OK
  else
    echo "COUCHDB AVAILABLE REPLICATIONS: no replications found"
    exit $STATE_WARNING 
  fi
fi

# Do the replication check for all replications
if [[ "${repid}" == "ALL" ]]; then
  httpget "/_scheduler/docs/_replicator"

  # Create stats array from response
  declare -a successrepls=( $(echo "$cdbresp" | jq -r '.docs[] | select(.state == "running").doc_id') )
  declare -a failedrepls=( $(echo "$cdbresp" | jq -r '.docs[] | select(.state != "running").doc_id') )
  declare -a error_count=( $(echo "$cdbresp" | jq -r '.docs[] | select(.state != "running").error_count') )
  declare -a state=( $(echo "$cdbresp" | jq -r '.docs[] | select(.state != "running").state') )

  if [[ ${#failedrepls[*]} -gt 0 ]]; then
    declare -a failedinfo=("")
    r=0
    for docid in ${failedrepls[*]}; do
	    #echo "Handling $docid" # Debug
	    if [[ $ignore_one_time == true ]]; then
	      httpget "/_replicator/${docid}"
	      continuous=$(echo "$cdbresp" | jq -r '.continuous' )
	      if [[ ${continuous} == false ]]; then
		      unset "failedrepls[${r}]"
	      fi
	    fi
	    failedinfo[${r}]="${docid} (state: ${state[${r}]}, error count: ${error_count[${r}]}) "
	    let r++
    done
  fi

  if [[ ${#failedrepls[*]} -gt 0 ]]; then
    echo "COUCHDB REPLICATION CRITICAL: ${#failedrepls[*]} continuous replications not running - Details: ${failedinfo[*]}"
    exit $STATE_CRITICAL
  else
    echo "COUCHDB REPLICATION OK - All ${#successrepls[*]} continuous replications running"; exit $STATE_OK
  fi

else
  # Do the replication check for a single replication
  httpget "/_scheduler/docs/_replicator/${repid}"
  repstatus=$(echo $cdbresp | jq -r '.state')
  
  if [[ "$repstatus" == "running" ]]; then
    echo "COUCHDB REPLICATION OK - Replication $repid is $repstatus"
    exit $STATE_OK
  else 
    echo "COUCHDB REPLICATION CRITICAL - Replication $repid is $repstatus"
    exit $STATE_CRITICAL
  fi
fi
