#!/bin/bash

# overall Che release orchestration script
# see ../README.md for more info

SCRIPT_DIR=$(cd "$(dirname "$0")" || exit; pwd)
REGISTRY="quay.io"
ORGANIZATION="eclipse"

die_with() 
{
	echo "$*" >&2
	exit 1
}

usage ()
{
  echo "Usage: $0  --version [CHE VERSION TO RELEASE] --dwo-version [DEVWORKSPACE OPERATOR VERSION TO RELEASE] --phases [LIST OF PHASES]

Phases are comma-separated list, e.g. '1,2,3,4,5,6', where each phase has its associated projects:
#1: MachineExec, CheTheia, DevfileRegistry, Dashboard, DwoOperator, JWTProxyAndKIP; 
#2: CheServer; 
#3: CheTheia; 
#4: ChePluginRegistry
#5: DwoCheOperator; 
#6: CheOperator; "

  echo "Example: $0 --version 7.29.0 --dwo-version 0.3.0 --phases 1,2,3,4,5,6"; echo
  exit 1
}

verifyContainerExistsWithTimeout()
{
    this_containerURL=$1
    this_timeout=$2
    containerExists=0
    count=1
    (( timeout_intervals=this_timeout*3 ))
    while [[ $count -le $timeout_intervals ]]; do # echo $count
        echo "       [$count/$timeout_intervals] Verify ${1} exists..." 
        # check if the container exists
        verifyContainerExists "$1"
        if [[ ${containerExists} -eq 1 ]]; then break; fi
        (( count=count+1 ))
        sleep 20s
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

installDebDeps(){
    set +x
    # TODO should this be node 12?
    curl -sL https://deb.nodesource.com/setup_10.x | sudo -E bash -
    sudo apt-get install -y nodejs
}

evaluateCheVariables() {
    echo "Che version: ${CHE_VERSION}"
    # derive branch from version
    BRANCH=${CHE_VERSION%.*}.x
    echo "Branch: ${BRANCH}"

    # if user accidentally entered 0.y.z instead of v0.y.z, prefix with the required "v"
    if [[ ${DWO_VERSION} != "v"* ]]; then DWO_VERSION="v${DWO_VERSION}"; fi

    DWO_BRANCH=${DWO_VERSION#v}
    DWO_BRANCH=${DWO_BRANCH%.*}.x
    echo "DWO Branch: ${DWO_BRANCH}"

    if [[ ${CHE_VERSION} == *".0" ]]; then
        BASEBRANCH="master"
    else
        BASEBRANCH="${BRANCH}"
    fi
    echo "Basebranch: ${BASEBRANCH}" 
    echo "Release Process Phases: '${PHASES}'"
}

# for a given GH repo and action name, compute workflow_id
# warning: variable workflow_id is a global, so don't call this in parallel executions!
computeWorkflowId() {
    this_repo=$1
    this_action_name=$2
    workflow_id=$(curl -sSL https://api.github.com/repos/${this_repo}/actions/workflows -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" | jq --arg search_field "${this_action_name}" '.workflows[] | select(.name == $search_field).id'); # echo "workflow_id = $workflow_id"
    if [[ ! $workflow_id ]]; then
        die_with "[ERROR] Could not compute workflow id from https://api.github.com/repos/${this_repo}/actions/workflows - check your GITHUB_TOKEN is active"
    fi
    # echo "[INFO] Got workflow_id $workflow_id for $this_repo action '$this_action_name'"
}

# generic method to call a GH action and pass in a single var=val parameter 
invokeAction() {
    this_repo=$1
    this_action_name=$2
    this_workflow_id=$3
    #params is a comma-separated list of key=value entries
    this_params=$4

    # if provided, use previously computed workflow_id; otherwise compute it from the action's name so we can invoke the GH action by id
    if [[ $this_workflow_id ]]; then
        workflow_id=$this_workflow_id
    else
        computeWorkflowId $this_repo "$this_action_name"
        # now we have a global value for $workflow_id
    fi

    if [[ ${this_repo} == "devfile/devworkspace-operator" ]] || [[ ${this_repo} == "che-incubator/devworkspace-che-operator" ]];then
        WORKFLOW_MAIN_BRANCH="main"
    else
        WORKFLOW_MAIN_BRANCH="master"
    fi

    if [[ ${this_repo} == "devfile/devworkspace-operator" ]];then
        WORKFLOW_BUGFIX_BRANCH=${DWO_BRANCH}
    else
        WORKFLOW_BUGFIX_BRANCH=${BRANCH}
    fi

    if [[ ${CHE_VERSION} == *".0" ]]; then
        workflow_ref=${WORKFLOW_MAIN_BRANCH}
    else
        workflow_ref=${WORKFLOW_BUGFIX_BRANCH}
    fi

    inputsJson="{}"

    IFS=',' read -ra paramMap <<< "${this_params}"
    for keyvalue in "${paramMap[@]}"
    do 
        key=${keyvalue%=*}
        value=${keyvalue#*=}
        echo $var1
        inputsJson=$(echo "${inputsJson}" | jq ". + {\"${key}\": \"${value}\"}")
    done

    if [[ ${this_repo} == "che-incubator"* ]] || [[ ${this_repo} == "devfile"* ]]; then
        this_github_token=${CHE_INCUBATOR_BOT_GITHUB_TOKEN}
    else
        this_github_token=${GITHUB_TOKEN}
    fi

    curl -sSL https://api.github.com/repos/${this_repo}/actions/workflows/${workflow_id}/dispatches -X POST -H "Authorization: token ${this_github_token}" -H "Accept: application/vnd.github.v3+json" -d "{\"ref\":\"${workflow_ref}\",\"inputs\": ${inputsJson} }" || die_with "[ERROR] Problem invoking action https://github.com/${this_repo}/actions?query=workflow%3A%22${this_action_name// /+}%22"
    echo "[INFO] Invoked '${this_action_name}' action ($workflow_id) - see https://github.com/${this_repo}/actions?query=workflow%3A%22${this_action_name// /+}%22"
}

releaseMachineExec() {
    invokeAction eclipse-che/che-machine-exec "Release Che Machine Exec" "5149341" "version=${CHE_VERSION}"
}

releaseCheTheia() {
    invokeAction eclipse-che/che-theia "Release Che Theia" "5717988" "version=${CHE_VERSION}"
}

releaseDevfileRegistry() {
    invokeAction eclipse-che/che-devfile-registry "Release Che Devfile Registry" "4191260" "version=${CHE_VERSION}"
}
releasePluginRegistry() {
    invokeAction eclipse-che/che-plugin-registry "Release Che Plugin Registry" "4191251" "version=${CHE_VERSION}"
}

branchJWTProxyAndKIP() {
    invokeAction eclipse/che-jwtproxy "Create branch" "5410230" "branch=${BRANCH}"
    invokeAction che-incubator/kubernetes-image-puller "Create branch" "5409996" "branch=${BRANCH}"
}

releaseDashboard() {
    invokeAction eclipse-che/che-dashboard "Release Che Dashboard" "3152474" "version=${CHE_VERSION}"
}

releaseCheServer() {
    invokeAction eclipse/che "Release Che Server" "5536792" "version=${CHE_VERSION}"
}

releaseCheOperator() {
    invokeAction eclipse-che/che-operator "Release Che Operator" "3593082" "version=${CHE_VERSION},dwoVersion=${DWO_VERSION},dwoCheVersion=v${CHE_VERSION}"
}

releaseDwoOperator() {
    invokeAction devfile/devworkspace-operator "Release DevWorkspace Operator" "6380164" "version=${DWO_VERSION}"
}

releaseDwoCheOperator() {
    invokeAction che-incubator/devworkspace-che-operator "Release DevWorkspace Che Operator" "6597719" "version=v${CHE_VERSION},dwoVersion=${DWO_VERSION}"
}

# TODO change it to someone else?
# TODO use a different token?
setupGitconfig() {
  git config --global user.name "Mykhailo Kuznietsov"
  git config --global user.email mkuznets@redhat.com

  # hub CLI configuration
  git config --global push.default matching

  # suppress warnings about how to reconcile divergent branches
  git config --global pull.ff only 

  # NOTE when invoking action from che-incubator/* repos (not eclipse/che* repos), must use CHE_INCUBATOR_BOT_GITHUB_TOKEN
  # default to CHE_BOT GH token
  export GITHUB_TOKEN="${CHE_BOT_GITHUB_TOKEN}"
}

while [[ "$#" -gt 0 ]]; do
  case $1 in
    '-v'|'--version') CHE_VERSION="$2"; shift 1;;
    '-dv'|'--dwo-version') DWO_VERSION="$2"; shift 1;;
    '-p'|'--phases') PHASES="$2"; shift 1;;
  esac
  shift 1
done

if [[ ! ${CHE_VERSION} ]] || [[ ! ${DWO_VERSION} ]] || [[ ! ${PHASES} ]] ; then
  usage
fi

set +x
mkdir $HOME/.ssh/
echo $CHE_GITHUB_SSH_KEY | base64 -d > $HOME/.ssh/id_rsa
chmod 0400 $HOME/.ssh/id_rsa
ssh-keyscan github.com >> ~/.ssh/known_hosts
set -x

installDebDeps
setupGitconfig

evaluateCheVariables
echo "BASH VERSION = $BASH_VERSION"
set -e

# Release projects that don't depend on other projects
set +x
if [[ ${PHASES} == *"1"* ]]; then
    releaseMachineExec
    releaseDevfileRegistry
    releaseDashboard
    releaseDwoOperator
    branchJWTProxyAndKIP
fi
wait
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-machine-exec:${CHE_VERSION} 60
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-devfile-registry:${CHE_VERSION} 60
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-dashboard:${CHE_VERSION} 60
# https://quay.io/repository/devfile/devworkspace-controller?tab=tags
verifyContainerExistsWithTimeout ${REGISTRY}/devfile/devworkspace-controller:${DWO_VERSION} 60


set +x
# Release server (depends on dashboard)
if [[ ${PHASES} == *"2"* ]]; then
    releaseCheServer
fi

IMAGES_LIST=(
    quay.io/eclipse/che-endpoint-watcher
    quay.io/eclipse/che-keycloak
    quay.io/eclipse/che-postgres
    quay.io/eclipse/che-dev
    quay.io/eclipse/che-server
    quay.io/eclipse/che-dashboard-dev
    quay.io/eclipse/che-e2e
)
if [[ ${PHASES} == *"2"* ]] || [[ ${PHASES} == *"3"* ]] || [[ ${PHASES} == *"6"* ]]; then
    # verify images all created from IMAGES_LIST
    for image in "${IMAGES_LIST[@]}"; do
        verifyContainerExistsWithTimeout ${image}:${CHE_VERSION} 60
    done
fi

# Release che-theia (depends on che-server's typescript dto)
if [[ ${PHASES} == *"3"* ]]; then
    releaseCheTheia
fi

if [[ ${PHASES} == *"3"* ]] || [[ ${PHASES} == *"6"* ]]; then
  verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-theia:${CHE_VERSION} 60
  verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-theia-dev:${CHE_VERSION} 60
  verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-theia-endpoint-runtime-binary:${CHE_VERSION} 60
fi

# Release plugin-registry (depends on che-theia and machine-exec)
if [[ ${PHASES} == *"4"* ]]; then
    releasePluginRegistry
fi

if [[ ${PHASES} == *"4"* ]] || [[ ${PHASES} == *"6"* ]]; then
  verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-plugin-registry:${CHE_VERSION} 30
fi

# Release devworkspace che operator (depends on devworkspace-operator)
# TODO this will go away when it's part of che-operator
if [[ ${PHASES} == *"5"* ]]; then
    releaseDwoCheOperator
fi

# TODO this will go away when it's part of che-operator
if [[ ${PHASES} == *"5"* ]] || [[ ${PHASES} == *"6"* ]]; then
    # https://quay.io/repository/che-incubator/devworkspace-che-operator?tab=tags
    verifyContainerExistsWithTimeout ${REGISTRY}/che-incubator/devworkspace-che-operator:v${CHE_VERSION} 30
fi

# Release Che operator (create PRs)
set +x
if [[ ${PHASES} == *"6"* ]]; then
    releaseCheOperator
fi
wait

# downstream steps depends on Che operator PRs being merged by humans, so this is the end of the automation.
# see ../README.md for more info
