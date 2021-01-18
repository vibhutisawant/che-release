#!/bin/bash

SCRIPT_DIR=$(cd "$(dirname "$0")" || exit; pwd)

function die_with() 
{
	echo "$*" >&2
	exit 1
}

releaseCheWorkspaceLoader()
{
    echo "1 second"
    sleep 3
    echo "3 seconds"
    die_with "dead"
}

verifyContainerExistsWithTimeout()
{
    this_containerURL=$1
    this_timeout=$2
    containerExists=0
    count=1
    (( timeout_intervals=this_timeout*3 ))
    while [[ $count -le $timeout_intervals ]]; do # echo $count
        sleep 20s
        echo "       [$count/$timeout_intervals] Verify ${1} exists..." 
        # check if the container exists
        verifyContainerExists "$1"
        if [[ ${containerExists} -eq 1 ]]; then break; fi
        (( count=count+1 ))
    done
    # or report an error
    if [[ ${containerExists} -eq 0 ]]; then
        echo "[ERROR] Did not find ${1} after ${this_timeout} minutes - script must exit!"
        exit 1;
    fi
}

# for a given container URL, check if it exists and its digest can be read
# verifyContainerExists quay.io/crw/pluginregistry-rhel8:2.6 # schemaVersion = 1, look for tag
# verifyContainerExists quay.io/eclipse/che-plugin-registry:7.24.2 # schemaVersion = 2, look for arches

verifyContainerExists()
{
    this_containerURL="${1}"
    this_image=""; this_tag=""
    this_image=${this_containerURL#*/}
    this_tag=${this_image##*:}
    this_image=${this_image%%:*}
    this_url="https://quay.io/v2/${this_image}/manifests/${this_tag}"
    # echo $this_url

    # get result=tag if tag found, result="null" if not
    result="$(curl -sSL "${this_url}"  -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" 2>&1 || true)"
    if [[ $(echo "$result" | jq -r '.schemaVersion' || true) == "1" ]] && [[ $(echo "$result" | jq -r '.tag' || true) == "$this_tag" ]]; then
        echo "[INFO] Found ${this_containerURL} (tag = $this_tag)"
        containerExists=1
    elif [[ $(echo "$result" | jq -r '.schemaVersion' || true) == "2" ]]; then
        arches=$(echo "$result" | jq -r '.manifests[].platform.architecture')
        if [[ $arches ]]; then
            echo "[INFO] Found ${this_containerURL} (arches = "$arches")"
        fi
        containerExists=1
    else
        # echo "[INFO] Did not find ${this_containerURL}"
        containerExists=0
    fi
}

waitForPids() {
    # TODO make this work
    pstree -p | grep -v grep > out
    cat out

    procs=$(pstree -p | grep -v grep | grep -E "cico_release_theia_and_registries|cico_release_dashboard_and_workspace_loader" | sed -r -e "s#--# #g")
    for p in $procs; do p=$(echo "${p}" | tr "|" -d | sed -r -e "s#.*\(([0-9]+)\).*#\1#g" | tr -d "-"); procslist="${procslist} ${p}"; done
    echo "JOB PIDs RUNNING:
     ----------
     $(jobs -rl)
     $procs
     ${procslist}
     ----------
     "
     
    echo "$*"
     wait $* || {
         echo  "Exit due to failure; kill running processes"
         trap "kill ${procslist} 2>/dev/null" EXIT
     exit 1
    }
}