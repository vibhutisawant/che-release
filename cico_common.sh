#!/bin/bash

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
        echo "[ERROR] Did not find ${$1} after ${this_timeout} minutes - script must exit!"
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