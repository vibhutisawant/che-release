#!/bin/bash

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
verifyContainerExists()
{
    this_containerURL="${1}"
    result="$(skopeo inspect "docker://${this_containerURL}" 2>&1)"
    if [[ $result == *"Error reading manifest"* ]] || [[ $result == *"no such image" ]] || [[ $result == *"manifest unknown" ]]; then # image does not exist
        containerExists=0
    else
        digest="$(echo "$result" | jq -r '.Digest' 2>&1)"
        if [[ $digest != "error"* ]] && [[ $digest != *"Invalid"* ]]; then
            containerExists=1
            echo "[INFO] Found ${this_containerURL} (${digest})"
        fi
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