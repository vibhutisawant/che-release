#!/bin/bash

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
    containerExists=0
    count=1
    (( timeout_intervals=timeout*3 ))
    while [[ $count -le $timeout_intervals ]]; do # echo $count
        sleep 20s
        echo "       [$count/$timeout_intervals] Verify ${containerURL} exists..." 
        # check if the container exists
        verifyContainerExists "${containerURL}"
        if [[ ${containerExists} -eq 1 ]]; then break; fi
        (( count=count+1 ))
    done
    # or report an error
    if [[ ${containerExists} -eq 0 ]]; then
        echo "[ERROR] Did not find ${containerURL} after ${timeout} minutes - script must exit!"
        exit 1;
    fi

    rm -f ./make-release.sh
    popd >/dev/null || exit
    echo 
}

# for a given container URL, check if it exists and its digest can be read
verifyContainerExists ()
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
