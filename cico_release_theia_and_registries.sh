#!/bin/bash

#include common scripts
. ./cico_common.sh

# this script should be called by cico_release.sh 
# this script requires skopeo and jq. To install: sudo yum install -y skopeo jq

# generic method to collect make-release script from a repo, run the script, and then wait until artifacts exist in quay
releaseCheContainer()
{
    # $1 - GIT project path, eg., eclipse/che-theia
    projectPath="${1}"

    # $2 - job name running the release build on https://ci.centos.org/view/Devtools/, eg., devtools-che-theia-che-release or devtools-che-machine-exec-release
    jobURL="https://ci.centos.org/view/Devtools/job/${2}/"

    # $3 - timeout in mins after which the script should fail, in 20s increments. Default: 120 mins
    if [[ "$3" ]]; then timeout="$3"; else timeout=120; fi

    # make-release.sh script, eg., https://raw.githubusercontent.com/eclipse/che-theia/master/make-release.sh
    makeReleaseURL="https://raw.githubusercontent.com/${projectPath}/master/make-release.sh"
    # container to wait for, eg., quay.io/eclipse/che-theia:7.11.0
    containerURL="quay.io/${projectPath}:${CHE_VERSION}"

    # version to tag & release in GH, eg., 7.11.0
    # also used as the tag to verify in quay
    containerVersion="${CHE_VERSION}"

    echo "[INFO] Release ${projectPath} ${CHE_VERSION}" 

    TMP=$(mktemp -d)
    pushd "$TMP" > /dev/null || exit 1

    # get the script & run it
    rm -f ./make-release.sh && curl -sSLO "${makeReleaseURL}" && chmod +x ./make-release.sh
    ./make-release.sh --repo "git@github.com:${projectPath}" --version "${containerVersion}" --trigger-release
    echo "[INFO] Running ${jobURL} ..." 

    # wait until the job has completed and the container is live
    verifyContainerExistsWithTimeout ${containerURL} ${timeout}

    rm -f ./make-release.sh
    popd >/dev/null || exit
    echo 
}

# collect commandline args in order:

# Che version, eg., 7.12.1
CHE_VERSION="$1"
# GIT project path, eg., eclipse/che-theia
projectPath="$2"
# job name running the release build on https://ci.centos.org/view/Devtools/, eg., devtools-che-theia-che-release or devtools-che-machine-exec-release
jobURL="$3"
# timeout in mins after which the script should fail
timeout="$4"

releaseCheContainer "$projectPath" "$jobURL" "$timeout"
