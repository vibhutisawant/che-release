#!/bin/bash

#include common scripts
. ./cico_common.sh

# this script should be called by cico_release.sh 
# this script requires skopeo and jq. To install: sudo yum install -y skopeo jq

# generic method to collect make-release script from a repo, run the script, and then wait until artifacts exist in quay
releaseCheContainer()
{
    directory="$1"
    containerURL="$2"
    echo "$1 $2"
    sleep 5
    if [[ $1 = "che-dashboard" ]]; then
        echo "error!"
        exit 1
    fi
    sleep 5
    echo "success!"
    exit 0
    # $3 - timeout in mins after which the script should fail, in 20s increments. Default: 120 mins
    #if [[ "$3" ]]; then timeout="$3"; else timeout=120; fi

    # pushd "$1" > /dev/null || exit 1
    # docker build -t ${containerURL} -f apache.Dockerfile .
    # if [[ $? -ne 0 ]]; then
    #     die_with  "docker build of ${containerURL} image is failed!"
    # fi

    # echo y | docker push ${containerURL}
    # if [[ $? -ne 0 ]]; then
    #     die_with  "docker push of ${containerURL} image is failed!"
    # fi

    # verifyContainerExistsWithTimeout ${containerURL} $3

    # echo "[INFO] $1 has been released"

    # popd >/dev/null || exit
    # echo 
}


# Project directory in which to perform a build, e.g. "che-dashboard"
directory="$1"
# Full container URL to push to, e.g. quay.io/eclipse/che-dashboard:7.14.0
containerURL="$2"
# timeout in mins after which the script should fail
timeout="$3"

releaseCheContainer "$directory" "$containerURL" "$timeout"
