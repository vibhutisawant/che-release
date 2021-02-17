#!/bin/bash

#include common scripts
. ./cico_common.sh

REGISTRY="quay.io"
ORGANIZATION="eclipse"

installRPMDeps(){
    set +x
    # enable epel and update to latest; update to git 2.24 via https://repo.ius.io/7/x86_64/packages/g/
    yum remove -y -q git* || true
    yum install -y -q https://repo.ius.io/ius-release-el7.rpm https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm || true
    yum-config-manager --add-repo https://dl.yarnpkg.com/rpm/yarn.repo
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    yum install -y -q centos-release-scl-rh subscription-manager
    subscription-manager repos --enable=rhel-server-rhscl-7-rpms || true
    yum update -y -q 
    # TODO should this be node 12 module?
    yum install -y -q git224-all skopeo java-11-openjdk-devel yum-utils device-mapper-persistent-data lvm2 docker-ce nodejs yarn gcc-c++ make jq hub python3-pip wget yq podman psmisc
    echo -n "node "; node --version
    echo -n "npm "; npm --version
    echo "Installed Packages" && rpm -qa | sort -V && echo "End Of Installed Packages"
    git --version || exit 1
    export JAVA_HOME=/usr/lib/jvm/java-11-openjdk
    export PATH="/usr/lib/jvm/java-11-openjdk:/usr/bin:${PATH:-/bin:/usr/bin}"
    export JAVACONFDIRS="/etc/java${JAVACONFDIRS:+:}${JAVACONFDIRS:-}"
    # TODO should this be node 12?
    curl -sL https://rpm.nodesource.com/setup_10.x | bash -
    # start docker daemon
    service docker start
}

installDebDeps(){
    set +x
    # TODO should this be node 12?
    curl -sL https://deb.nodesource.com/setup_10.x | sudo -E bash -
    sudo apt-get install -y nodejs
}

evaluateCheVariables() {
    source VERSION
    echo "Che version: ${CHE_VERSION}"
    # derive branch from version
    BRANCH=${CHE_VERSION%.*}.x
    echo "Branch: ${BRANCH}"

    if [[ ${CHE_VERSION} == *".0" ]]; then
        BASEBRANCH="master"
    else
        BASEBRANCH="${BRANCH}"
    fi
    echo "Basebranch: ${BASEBRANCH}" 
    echo "Release che-parent: ${RELEASE_CHE_PARENT}"
    echo "Version che-parent: ${VERSION_CHE_PARENT}"
    echo "Deploy to nexus: ${DEPLOY_TO_NEXUS}"
    echo "Autorelease on nexus: ${AUTORELEASE_ON_NEXUS}"
    echo "Release Process Phases: '${PHASES}'"
}

# che docs release now depends on che-operator completion.
# issue: https://github.com/eclipse/che/issues/18864
# see https://github.com/eclipse/che-docs/pull/1823
# see https://github.com/eclipse/che-operator/pull/657
# releaseCheDocs() {
#     tmpdir="$(mktemp -d)"
#     pushd "${tmpdir}" >/dev/null || exit
#     projectPath=eclipse/che-docs
#     rm -f ./make-release.sh && curl -sSLO "https://raw.githubusercontent.com/${projectPath}/master/make-release.sh" && chmod +x ./make-release.sh
#     ./make-release.sh --repo "git@github.com:${projectPath}" --version "${CHE_VERSION}" --trigger-release
#     popd >/dev/null || exit 
# }

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
    this_var=$4
    this_val=$5

    # if provided, use previously computed workflow_id; otherwise compute it from the action's name so we can invoke the GH action by id
    if [[ $this_workflow_id ]]; then
        workflow_id=$this_workflow_id
    else
        computeWorkflowId $this_repo "$this_action_name"
        # now we have a global value for $workflow_id
    fi
    if [[ ${this_repo} == "che-incubator"* ]]; then
        this_github_token=${CHE_INCUBATOR_BOT_GITHUB_TOKEN}
    else
        this_github_token=${GITHUB_TOKEN}
    fi

    curl -sSL https://api.github.com/repos/${this_repo}/actions/workflows/${workflow_id}/dispatches -X POST -H "Authorization: token ${this_github_token}" -H "Accept: application/vnd.github.v3+json" -d "{\"ref\":\"master\",\"inputs\": {\"${this_var}\":\"${this_val}\"} }" || die_with "[ERROR] Problem invoking action https://github.com/${this_repo}/actions?query=workflow%3A%22${this_action_name// /+}%22"
    echo "[INFO] Invoked '${this_action_name}' action ($workflow_id) - see https://github.com/${this_repo}/actions?query=workflow%3A%22${this_action_name// /+}%22"
}

releaseMachineExec() {
    invokeAction eclipse/che-machine-exec "Release Che Machine Exec" "5149341" version "${CHE_VERSION}"
}

releaseCheTheia() {
    invokeAction eclipse/che-theia "Release Che Theia" "5717988" version "${CHE_VERSION}"
}

branchJWTProxyAndKIP() {
    invokeAction eclipse/che-jwtproxy "Create branch" "5410230" branch "${BRANCH}"
    invokeAction che-incubator/kubernetes-image-puller "Create branch" "5409996" branch "${BRANCH}"
}

releaseDashboardAndWorkspaceLoader() {
    invokeAction eclipse/che-dashboard "Release Che Dashboard" "3152474" version "${CHE_VERSION}"
    invokeAction eclipse/che-workspace-loader "Release Che Workspace Loader" "3543888" version "${CHE_VERSION}"
}

releaseCheServer() {
    invokeAction eclipse/che-server "Release Che Server" "5536792" version "${CHE_VERSION}"
}

releaseOperator() {
    invokeAction eclipse/che-operator "Release Che Operator" "3593082" version "${CHE_VERSION}"
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

# Release che-theia, machine-exec and devfile-registry
set +x
if [[ ${PHASES} == *"1"* ]]; then
    releaseMachineExec
    releaseCheTheia
    # TODO switch to GH action https://github.com/eclipse/che-devfile-registry/pull/309 + need secrets 
    { ./cico_release_theia_and_registries.sh ${CHE_VERSION} eclipse/che-devfile-registry devtools-che-devfile-registry-release 75 & }; pid_3=$!;
    releaseDashboardAndWorkspaceLoader
    branchJWTProxyAndKIP

fi
wait
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-machine-exec:${CHE_VERSION} 30
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-devfile-registry:${CHE_VERSION} 30
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-theia-dev:${CHE_VERSION} 30
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-theia:${CHE_VERSION} 30
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-theia-endpoint-runtime-binary:${CHE_VERSION} 30
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-dashboard:${CHE_VERSION} 30
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-workspace-loader:${CHE_VERSION} 30

# Release plugin-registry (depends on che-theia and machine-exec)
set +x
if [[ ${PHASES} == *"2"* ]]; then
    # TODO switch to GH action https://github.com/eclipse/che-plugin-registry/pull/723 + need secrets 
    { ./cico_release_theia_and_registries.sh ${CHE_VERSION} eclipse/che-plugin-registry  devtools-che-plugin-registry-release  45 & }; pid_4=$!;
    releaseCheServer
fi
wait
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-plugin-registry:${CHE_VERSION} 30
# verify images all created from IMAGES_LIST
for image in ${IMAGES_LIST[@]}; do
    verifyContainerExistsWithTimeout ${image}:${CHE_VERSION} 60
done

# Release Che operator (create PRs)
set +x
if [[ ${PHASES} == *"3"* ]]; then
    releaseOperator
fi

# TODO need a test to validate docs have been published OK
wait

# Next steps documented in https://github.com/eclipse/che-release/blob/master/README.md#phase-2---manual-steps