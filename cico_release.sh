#!/bin/bash

#include common scripts
. ./cico_common.sh

# TODO make this work for GH action
loadJenkinsVars() {
    if [[ -x ./env-toolkit ]]; then
        set +x
        eval "$(./env-toolkit load -f jenkins-env.json \
                                CHE_BOT_GITHUB_TOKEN \
                                CHE_MAVEN_SETTINGS \
                                CHE_GITHUB_SSH_KEY \
                                CHE_NPM_AUTH_TOKEN \
                                CHE_OSS_SONATYPE_GPG_KEY \
                                CHE_OSS_SONATYPE_PASSPHRASE \
                                RH_CHE_AUTOMATION_DOCKERHUB_USERNAME \
                                RH_CHE_AUTOMATION_DOCKERHUB_PASSWORD \
                                QUAY_ECLIPSE_CHE_USERNAME \
                                QUAY_ECLIPSE_CHE_PASSWORD \
                                QUAY_ECLIPSE_CHE_OPERATOR_KUBERNETES_USERNAME \
                                QUAY_ECLIPSE_CHE_OPERATOR_KUBERNETES_PASSWORD \
                                QUAY_ECLIPSE_CHE_OPERATOR_OPENSHIFT_USERNAME \
                                QUAY_ECLIPSE_CHE_OPERATOR_OPENSHIFT_PASSWORD)"
    fi
    # TODO make this work for GH action - where do we get NPM_AUTH_TOKEN ?
    if [[ $NPM_AUTH_TOKEN ]]; then
        export NPM_AUTH_TOKEN=${CHE_NPM_AUTH_TOKEN}
    fi
}

# TODO make this work for GH action
loadMvnSettingsGpgKey() {
    set +x
    mkdir $HOME/.m2
    #prepare settings.xml for maven and sonatype (central maven repository)
    echo $CHE_MAVEN_SETTINGS | base64 -d > $HOME/.m2/settings.xml 
    #load GPG key for sign artifacts
    echo $CHE_OSS_SONATYPE_GPG_KEY | base64 -d > $HOME/.m2/gpg.key
    #load SSH key for release process
    echo ${#CHE_OSS_SONATYPE_GPG_KEY}
    echo $CHE_GITHUB_SSH_KEY | base64 -d > $HOME/.ssh/id_rsa
    chmod 0400 $HOME/.ssh/id_rsa
    ssh-keyscan github.com >> ~/.ssh/known_hosts
    set -x
    export GPG_TTY=$(tty)
    gpg --import $HOME/.m2/gpg.key
    # gpg --import --batch $HOME/.m2/gpg.key
    gpg --version
}

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

installMaven(){
    set -x
    mkdir -p /opt/apache-maven && curl -sSL https://downloads.apache.org/maven/maven-3/3.6.3/binaries/apache-maven-3.6.3-bin.tar.gz | tar -xz --strip=1 -C /opt/apache-maven
    export M2_HOME="/opt/apache-maven"
    export PATH="/opt/apache-maven/bin:${PATH}"
    mvn -version || die_with "mvn not found in path: ${PATH} !"
    set +x
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

releaseCheDocs() {
    tmpdir="$(mktemp -d)"
    pushd "${tmpdir}" >/dev/null || exit
    projectPath=eclipse/che-docs
    rm -f ./make-release.sh && curl -sSLO "https://raw.githubusercontent.com/${projectPath}/master/make-release.sh" && chmod +x ./make-release.sh
    ./make-release.sh --repo "git@github.com:${projectPath}" --version "${CHE_VERSION}" --trigger-release
    popd >/dev/null || exit 
}

releaseDashboard() {
    echo "[INFO] Invoke che-dashboard release action: https://github.com/eclipse/che-dashboard/actions?query=workflow%3A%22Release+Che+Dashboard%22"
    curl https://api.github.com/repos/eclipse/che-dashboard/actions/workflows/3152474/dispatches -X POST -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" -d "{\"ref\":\"master\",\"inputs\": {\"version\":\"${CHE_VERSION}\"} }"
}

releaseWorkspaceLoader() {
    echo "[INFO] Invoke che-workspace-loader release action: https://github.com/eclipse/che-workspace-loader/actions?query=workflow%3A%22Release+Che+Workspace+Loader%22"
    curl https://api.github.com/repos/eclipse/che-workspace-loader/actions/workflows/3543888/dispatches -X POST -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" -d "{\"ref\":\"master\",\"inputs\": {\"version\":\"${CHE_VERSION}\"} }"
}

# check for build errors, since we're using set +e above to NOT fail the build for Nexus problems
checkLogForErrors () {
    tmplog="$1"
    errors_in_log="$(grep -E "FAILURE \[|BUILD FAILURE|Failed to execute goal" $tmplog || true)"
    if [[ ${errors_in_log} ]]; then
        echo "${errors_in_log}"
        exit 1
    fi
}

releaseCheServer() {
    set -x
    tmpmvnlog=/tmp/mvn.log.txt
    if [[ $RELEASE_CHE_PARENT = "true" ]]; then
        pushd che-parent >/dev/null
        rm -f $tmpmvnlog || true
        set +e
        mvn clean install -ntp -U -Pcodenvy-release -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE | tee $tmpmvnlog
        EXIT_CODE=$?
        set -e
        # try maven build again if Nexus dies
        if grep -q -E "502 - Bad Gateway|Nexus connection problem" $tmpmvnlog; then
            rm -f $tmpmvnlog || true
            mvn clean install -ntp -U -Pcodenvy-release -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE | tee $tmpmvnlog
            EXIT_CODE=$?
        fi
        # check log for errors if build successful; if failed, no need to check (already failed)
        if [ $EXIT_CODE -eq 0 ]; then
            checkLogForErrors $tmpmvnlog
            echo 'Build of che-parent: Success!'
            if [[ ${DEPLOY_TO_NEXUS} == "true" ]]; then
                echo 'Deploy che-parent artifacts to nexus'
                rm -f $tmpmvnlog || true
                set +e
                mvn clean deploy -ntp -Pcodenvy-release -DcreateChecksum=true -DautoReleaseAfterClose=$AUTORELEASE_ON_NEXUS -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE | tee $tmpmvnlog
                EXIT_CODE=$?
                set -e
                # try maven build again if Nexus dies
                if grep -q -E "502 - Bad Gateway|Nexus connection problem" $tmpmvnlog; then
                    rm -f $tmpmvnlog || true
                    mvn clean deploy -ntp -Pcodenvy-release -DcreateChecksum=true -DautoReleaseAfterClose=$AUTORELEASE_ON_NEXUS -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE | tee $tmpmvnlog
                    EXIT_CODE=$?
                fi
                # check log for errors if build successful; if failed, no need to check (already failed)
                if [[ $EXIT_CODE -eq 0 ]]; then
                    checkLogForErrors $tmpmvnlog
                else
                    echo '[ERROR] 1. Build of che-parent: Failed!'
                    exit $EXIT_CODE
                fi
            else
                echo "[WARN] No deployment to Nexus as DEPLOY_TO_NEXUS = ${DEPLOY_TO_NEXUS}"
            fi
        else
            echo '[ERROR] 2. Build of che-parent: Failed!'
            exit $EXIT_CODE
        fi
        popd >/dev/null
    fi

    pushd che >/dev/null
    rm -f $tmpmvnlog || true
    set +e
    mvn clean install -U -Pcodenvy-release -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE | tee $tmpmvnlog
    EXIT_CODE=$?
    set -e
    # try maven build again if Nexus dies
    if grep -q -E "502 - Bad Gateway|Nexus connection problem" $tmpmvnlog; then
        rm -f $tmpmvnlog || true
        mvn clean install -U -Pcodenvy-release -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE | tee $tmpmvnlog
        EXIT_CODE=$?
    fi

    # check log for errors if build successful; if failed, no need to check (already failed)
    if [ $EXIT_CODE -eq 0 ]; then
        checkLogForErrors $tmpmvnlog
        echo 'Build of che-server: Success!'
        if [[ ${DEPLOY_TO_NEXUS} == "true" ]]; then
            echo 'Deploy che-server artifacts to nexus'
            rm -f $tmpmvnlog || true
            set +e
            mvn clean deploy -Pcodenvy-release -DcreateChecksum=true -DautoReleaseAfterClose=$AUTORELEASE_ON_NEXUS -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE | tee $tmpmvnlog
            EXIT_CODE=$?
            set -e
            # try maven build again if Nexus dies
            if grep -q -E "502 - Bad Gateway|Nexus connection problem" $tmpmvnlog; then
                rm -f $tmpmvnlog || true
                mvn clean deploy -Pcodenvy-release -DcreateChecksum=true -DautoReleaseAfterClose=$AUTORELEASE_ON_NEXUS -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE | tee $tmpmvnlog
                EXIT_CODE=$?
            fi
            if [[ $EXIT_CODE -eq 0 ]]; then
                checkLogForErrors $tmpmvnlog
            else
                echo '[ERROR] 1. Build of che-server: Failed!'
                exit $EXIT_CODE
            fi
        else
            echo "[WARN] No deployment to Nexus as DEPLOY_TO_NEXUS = ${DEPLOY_TO_NEXUS}"
        fi
    else
        echo '[ERROR] 2. Build of che-server: Failed!'
        exit $EXIT_CODE
    fi
    set +x
    popd >/dev/null
}

releaseTypescriptDto() {
    cd che/typescript-dto
    sed -i build.sh -e "s/3.3-jdk-8/3.6.3-jdk-11/g"
    set +e
    ./build.sh
    set -e
    git checkout -- .
    cd ../..
}

# TODO ensure usage of respective bugfix branches
checkoutProjects() {
    checkoutProject git@github.com:eclipse/che-parent
    checkoutProject git@github.com:eclipse/che
}

checkoutProject() {
    PROJECT="${1##*/}"
    echo "checking out project $PROJECT with ${BRANCH} branch"

    git clone $1
    cd $PROJECT
    git checkout ${BASEBRANCH}

    set -x
    set +e
    if [[ "${BASEBRANCH}" != "${BRANCH}" ]]; then
        git branch "${BRANCH}" || git checkout "${BRANCH}" && git pull origin "${BRANCH}"
        git push origin "${BRANCH}"
        git fetch origin "${BRANCH}:${BRANCH}"
        git checkout "${BRANCH}"
    fi
    set -e
    set +x
    cd ..

}

# TODO change it to someone else?
# TODO use a different token?
setupGitconfig() {
  git config --global user.name "Mykhailo Kuznietsov"
  git config --global user.email mkuznets@redhat.com

  # hub CLI configuration
  git config --global push.default matching
  export GITHUB_TOKEN="${CHE_BOT_GITHUB_TOKEN}"
}

createTags() {
    if [[ $RELEASE_CHE_PARENT = "true" ]]; then
        tagAndCommit che-parent
    fi
    tagAndCommit che
}

tagAndCommit() {
    cd $1
    # this branch isn't meant to be pushed
    git checkout -b release-${CHE_VERSION}
    git commit -asm "Release version ${CHE_VERSION}"
    if [ $(git tag -l "$CHE_VERSION") ]; then
        echo "tag ${CHE_VERSION} already exists! recreating ..."
        git tag -d ${CHE_VERSION}
        git push origin :${CHE_VERSION}
        git tag "${CHE_VERSION}"
    else
        echo "[INFO] creating new tag ${CHE_VERSION}"
        git tag "${CHE_VERSION}"
    fi
    git push --tags
    echo "[INFO] tag created and pushed for $1"
    cd ..
}

 # KEEP RIGHT ORDER!!!
DOCKER_FILES_LOCATIONS=(
    che/dockerfiles/endpoint-watcher
    che/dockerfiles/keycloak
    che/dockerfiles/postgres
    che/dockerfiles/dev
    che/dockerfiles/che
    che/dockerfiles/dashboard-dev
    che/dockerfiles/e2e
)

IMAGES_LIST=(
    quay.io/eclipse/che-endpoint-watcher
    quay.io/eclipse/che-keycloak
    quay.io/eclipse/che-postgres
    quay.io/eclipse/che-dev
    quay.io/eclipse/che-server
    quay.io/eclipse/che-dashboard-dev
    quay.io/eclipse/che-e2e
)

REGISTRY="quay.io"
ORGANIZATION="eclipse"

buildImages() {
    echo "Going to build docker images"
    set -e
    set -o pipefail
    TAG=$1
  
    # stop / rm all containers
    if [[ $(docker ps -aq) != "" ]];then
        docker rm -f "$(docker ps -aq)"
    fi

    # BUILD IMAGES
    for image_dir in ${DOCKER_FILES_LOCATIONS[@]}
      do
        if [[ ${image_dir} == "che/dockerfiles/che" ]]; then
          bash "$(pwd)/${image_dir}/build.sh" --tag:${TAG} --build-arg:"CHE_DASHBOARD_VERSION=${CHE_VERSION},CHE_WORKSPACE_LOADER_VERSION=${CHE_VERSION}"  
        else
          bash "$(pwd)/${image_dir}/build.sh" --tag:${TAG} 
        fi
        if [[ $? -ne 0 ]]; then
           echo "ERROR:"
           echo "build of '${image_dir}' image is failed!"
           exit 1
        fi
      done
}

tagLatestImages() {
    for image in ${IMAGES_LIST[@]}
     do
         echo y | docker tag "${image}:$1" "${image}:latest"
         if [[ $? -ne 0 ]]; then
           die_with  "docker tag of '${image}' image is failed!"
         fi
     done
}

loginToRegistries() {
    if [[ -n "${QUAY_ECLIPSE_CHE_USERNAME}" ]] && [[ -n "${QUAY_ECLIPSE_CHE_PASSWORD}" ]]; then
        echo "${QUAY_ECLIPSE_CHE_PASSWORD}" | docker login -u "${QUAY_ECLIPSE_CHE_USERNAME}" --password-stdin "${REGISTRY}"
    else
        echo "Could not login, missing credentials for ${REGISTRY}/${ORGANIZATION}"
        die_with  "failed to login to ${REGISTRY}!"
    fi

    if [ -n "${RH_CHE_AUTOMATION_DOCKERHUB_USERNAME}" ] && [ -n "${RH_CHE_AUTOMATION_DOCKERHUB_PASSWORD}" ]; then
        echo "${RH_CHE_AUTOMATION_DOCKERHUB_PASSWORD}" | docker login -u "${RH_CHE_AUTOMATION_DOCKERHUB_USERNAME}" --password-stdin docker.io
    else
        echo "Could not login, missing credentials for docker.io"
        die_with  "failed to login to docker.io!"
    fi
}

pushImagesOnQuay() {
    #PUSH IMAGES
    for image in ${IMAGES_LIST[@]}
        do
            echo y | docker push "${image}:$1"
            if [[ $2 == "pushLatest" ]]; then
                echo y | docker push "${image}:latest"
            fi
            if [[ $? -ne 0 ]]; then
            die_with  "docker push of '${image}' image is failed!"
            fi
        done
}

commitChangeOrCreatePR() {
    set +e
    aVERSION="$1"
    aBRANCH="$2"
    PR_BRANCH="$3"

    COMMIT_MSG="[release] Bump to ${aVERSION} in ${aBRANCH}"

    # commit change into branch
    git commit -asm "${COMMIT_MSG}"
    git pull origin "${aBRANCH}"

    PUSH_TRY="$(git push origin "${aBRANCH}")"
    # shellcheck disable=SC2181
    if [[ $? -gt 0 ]] || [[ $PUSH_TRY == *"protected branch hook declined"* ]]; then
        # create pull request for master branch, as branch is restricted
        git branch "${PR_BRANCH}"
        git checkout "${PR_BRANCH}"
        git pull origin "${PR_BRANCH}"
        git push origin "${PR_BRANCH}"
        lastCommitComment="$(git log -1 --pretty=%B)"
        hub pull-request -f -m "${lastCommitComment}" -b "${aBRANCH}" -h "${PR_BRANCH}"
    fi
    set -e
}

bumpVersion() {
    set -x
    echo "[info]bumping to version $1 in branch $2"

    if [[ $RELEASE_CHE_PARENT = "true" ]]; then
        pushd che-parent >/dev/null
        git checkout $2
        #install previous version, in case it is not available in central repo
        #which is needed for dependent projects
        
        mvn clean install
        mvn versions:set -DgenerateBackupPoms=false -DnewVersion=${CHE_VERSION}
        mvn clean install
        commitChangeOrCreatePR ${CHE_VERSION} $2 "pr-${2}-to-${1}"
        popd >/dev/null
    fi

    pushd che >/dev/null
        git checkout $2
        if [[ $RELEASE_CHE_PARENT = "true" ]]; then
            mvn versions:update-parent -DgenerateBackupPoms=false -DallowSnapshots=true -DparentVersion=[${VERSION_CHE_PARENT}]
        fi
        mvn versions:set -DgenerateBackupPoms=false -DallowSnapshots=true -DnewVersion=$1
        sed -i -e "s#<che.dashboard.version>.*<\/che.dashboard.version>#<che.dashboard.version>$1<\/che.dashboard.version>#" pom.xml
        sed -i -e "s#<che.version>.*<\/che.version>#<che.version>$1<\/che.version>#" pom.xml
        pushd typescript-dto >/dev/null
            sed -i -e "s#<che.version>.*<\/che.version>#<che.version>${1}<\/che.version>#" dto-pom.xml
            sed -i -e "s#<version>.*<\/version>#<version>${1}<\/version>#" dto-pom.xml
        popd >/dev/null

        commitChangeOrCreatePR $1 $2 "pr-${2}-to-${1}"
    popd >/dev/null
    set +x
}

updateImageTagsInCheServer() {
    cd che
    git checkout ${BRANCH}
    cd .ci
    ./set_tag_version_images.sh ${CHE_VERSION}
    cd ..
    git commit -asm "Set ${CHE_VERSION} release image tags"
    git push origin ${BRANCH}
}

prepareRelease() {
    if [[ $RELEASE_CHE_PARENT = "true" ]]; then
        pushd che-parent >/dev/null
            # Install previous version, in case it is not available in central repo
            # which is needed for dependent projects
            mvn clean install
            mvn versions:set -DgenerateBackupPoms=false -DnewVersion=${VERSION_CHE_PARENT}
            mvn clean install
        popd >/dev/null
        echo "[INFO] Che Parent version has been updated to ${VERSION_CHE_PARENT}"
    fi

    pushd che >/dev/null
        if [[ $RELEASE_CHE_PARENT = "true" ]]; then
            mvn versions:update-parent -DgenerateBackupPoms=false -DallowSnapshots=false -DparentVersion=[${VERSION_CHE_PARENT}]
        fi
        mvn versions:set -DgenerateBackupPoms=false -DallowSnapshots=false -DnewVersion=${CHE_VERSION}
        echo "[INFO] Che Server version has been updated to ${CHE_VERSION} (parentVersion = ${VERSION_CHE_PARENT})"

        # Replace dependencies in che-server parent
        sed -i -e "s#<che.dashboard.version>.*<\/che.dashboard.version>#<che.dashboard.version>${CHE_VERSION}<\/che.dashboard.version>#" pom.xml
        sed -i -e "s#<che.version>.*<\/che.version>#<che.version>${CHE_VERSION}<\/che.version>#" pom.xml
        echo "[INFO] Dependencies updated in che-server parent"

        # TODO pull parent pom version from VERSION file, instead of being hardcoded
        pushd typescript-dto >/dev/null
            sed -i -e "s#<che.version>.*<\/che.version>#<che.version>${CHE_VERSION}<\/che.version>#" dto-pom.xml
            # Do not change the version of the parent pom, which is fixed
            # TODO is this correct? seems like we're setting parent to a version that doesn't exist, rather than hardcoding to VERSION_CHE_PARENT value
            sed -i -e "/<version>${VERSION_CHE_PARENT}<\/version>/ ! s#<version>.*<\/version>#<version>${CHE_VERSION}<\/version>#" dto-pom.xml
            echo "[INFO] Dependencies updated in che typescript DTO (should have parent = ${VERSION_CHE_PARENT}, not ${CHE_VERSION})"
        popd >/dev/null

        # TODO more elegant way to execute these scripts
        pushd .ci >/dev/null
            ./set_tag_version_images.sh ${CHE_VERSION}
            echo "[INFO] Tag versions of images have been set in che-server"
        popd >/dev/null
    popd >/dev/null
}

bumpVersions() {
    # infer project version + commit change into ${BASEBRANCH} branch
    echo "${BASEBRANCH} ${BRANCH}"
    if [[ "${BASEBRANCH}" != "${BRANCH}" ]]; then
        # bump the y digit
        [[ ${BRANCH} =~ ^([0-9]+)\.([0-9]+)\.x ]] && BASE=${BASH_REMATCH[1]}; NEXT=${BASH_REMATCH[2]}; (( NEXT=NEXT+1 )) # for BRANCH=7.10.x, get BASE=7, NEXT=11
        NEXTVERSION_Y="${BASE}.${NEXT}.0-SNAPSHOT"
        bumpVersion ${NEXTVERSION_Y} ${BASEBRANCH}
    fi
    # bump the z digit
    [[ ${CHE_VERSION} =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]] && BASE="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"; NEXT="${BASH_REMATCH[3]}"; (( NEXT=NEXT+1 )) # for VERSION=7.7.1, get BASE=7.7, NEXT=2
    NEXTVERSION_Z="${BASE}.${NEXT}-SNAPSHOT"
    bumpVersion ${NEXTVERSION_Z} ${BRANCH}
}

releaseOperator() {
    echo "[INFO] Invoke che-operator release action: https://github.com/eclipse/che-operator/actions?query=workflow%3Arelease"
    curl https://api.github.com/repos/eclipse/che-operator/actions/workflows/3593082/dispatches -X POST -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" -d "{\"ref\":\"master\",\"inputs\": {\"version\":\"${CHE_VERSION}\"} }"
}

if [[ $1 == "ubuntu" ]]; then
    # TODO make this work for GH action - where do we get NPM_AUTH_TOKEN ?
    loadJenkinsVars
    # TODO make this work for GH action
    mkdir $HOME/.ssh/
    loadMvnSettingsGpgKey
    installDebDeps
    set -x
    setupGitconfig
    # TODO: shouldn't need to do this if using GH action to log in
    # loginToRegistries
else
    loadJenkinsVars
    loadMvnSettingsGpgKey
    installRPMDeps
    set -x
    setupGitconfig
    loginToRegistries
fi

evaluateCheVariables
echo "BASH VERSION = $BASH_VERSION"
set -e

# Release che-theia, machine-exec and devfile-registry
set +x
if [[ ${PHASES} == *"1"* ]]; then
    { ./cico_release_theia_and_registries.sh ${CHE_VERSION} eclipse/che-theia            devtools-che-theia-che-release        90 & }; pid_1=$!;
    { ./cico_release_theia_and_registries.sh ${CHE_VERSION} eclipse/che-machine-exec     devtools-che-machine-exec-release     60 & }; pid_2=$!;
    # TODO switch to GH action https://github.com/eclipse/che-devfile-registry/pull/309 + need secrets 
    { ./cico_release_theia_and_registries.sh ${CHE_VERSION} eclipse/che-devfile-registry devtools-che-devfile-registry-release 75 & }; pid_3=$!;
fi
wait
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-machine-exec:${CHE_VERSION} 30
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-devfile-registry:${CHE_VERSION} 30
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-theia-dev:${CHE_VERSION} 30
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-theia:${CHE_VERSION} 30
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-theia-endpoint-runtime-binary:${CHE_VERSION} 30

# Release plugin-registry (depends on che-theia and machine-exec)
set +x
if [[ ${PHASES} == *"2"* ]]; then
    # TODO switch to GH action https://github.com/eclipse/che-plugin-registry/pull/723 + need secrets 
    { ./cico_release_theia_and_registries.sh ${CHE_VERSION} eclipse/che-plugin-registry  devtools-che-plugin-registry-release  45 & }; pid_4=$!;
fi
wait
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-plugin-registry:${CHE_VERSION} 30

# Release dashboard and workspace loader
set +x
if [[ ${PHASES} == *"3"* ]]; then
    releaseDashboard
    releaseWorkspaceLoader
fi
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-dashboard:${CHE_VERSION} 30
verifyContainerExistsWithTimeout ${REGISTRY}/${ORGANIZATION}/che-workspace-loader:${CHE_VERSION} 30

# Release of Che docs does not depend on server, so trigger and don't wait
set +x
if [[ ${PHASES} == *"4"* ]]; then
    releaseCheDocs &
fi

set +x
# only need maven for che server (5) + bumping versions in sources (6)
if [[ ${PHASES} == *"5"* ]] || [[ ${PHASES} == *"6"* ]]; then
    installMaven
fi

# Release Che server to Maven central (depends on dashboard and workspace loader)
set +x
if [[ ${PHASES} == *"5"* ]]; then
    checkoutProjects
    prepareRelease
    createTags
    releaseCheServer
fi

# Release Che images - see DOCKER_FILES_LOCATIONS for array of images to build
set +x
if [[ ${PHASES} == *"6"* ]]; then
    buildImages  ${CHE_VERSION}
    tagLatestImages ${CHE_VERSION}
    pushImagesOnQuay ${CHE_VERSION} pushLatest
    bumpVersions
    updateImageTagsInCheServer

    # verify images all created from IMAGES_LIST
    for image in ${IMAGES_LIST[@]}; do
        verifyContainerExistsWithTimeout ${image}:${CHE_VERSION} 30
    done
fi

# Release Che operator (create PRs)
set +x
if [[ ${PHASES} == *"7"* ]]; then
    releaseOperator
fi

# TODO need a test to validate docs have been published OK
wait

# Next steps documented in https://github.com/eclipse/che-release/blob/master/README.md#phase-2---manual-steps