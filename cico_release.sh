#!/bin/bash

#include common scripts
. ./cico_common.sh

loadJenkinsVars() {
    set +x
    eval "$(./env-toolkit load -f jenkins-env.json \
                              CHE_BOT_GITHUB_TOKEN \
                              CHE_MAVEN_SETTINGS \
                              CHE_GITHUB_SSH_KEY \
                              CHE_OSS_SONATYPE_GPG_KEY \
                              CHE_OSS_SONATYPE_PASSPHRASE \
                              QUAY_ECLIPSE_CHE_USERNAME \
                              QUAY_ECLIPSE_CHE_PASSWORD)"
}

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
    gpg --import $HOME/.m2/gpg.key
}

installDeps(){
    set +x
    yum -y update 
    yum -y install git skopeo
    yum -y install java-11-openjdk-devel git
    mkdir -p /opt/apache-maven && curl -sSL https://downloads.apache.org/maven/maven-3/3.6.3/binaries/apache-maven-3.6.3-bin.tar.gz | tar -xz --strip=1 -C /opt/apache-maven
    export JAVA_HOME=/usr/lib/jvm/java-11-openjdk
    export PATH="/usr/lib/jvm/java-11-openjdk:/opt/apache-maven/bin:/usr/bin:${PATH:-/bin:/usr/bin}"
    export JAVACONFDIRS="/etc/java${JAVACONFDIRS:+:}${JAVACONFDIRS:-}"
    export M2_HOME="/opt/apache-maven"
    yum install -y yum-utils device-mapper-persistent-data lvm2
    yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    curl -sL https://rpm.nodesource.com/setup_10.x | bash -
    yum-config-manager --add-repo https://dl.yarnpkg.com/rpm/yarn.repo
    yum install -y docker-ce nodejs yarn gcc-c++ make jq hub
    yum install -y python3-pip wget yq podman
    yum install -y psmisc
    echo "BASH VERSION = $BASH_VERSION"
    service docker start
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

    echo "Autorelease on nexus: ${AUTORELEASE_ON_NEXUS}"
}

releaseCheDashboard()
{   
    cd che-dashboard
    containerURL="${REGISTRY}/${ORGANIZATION}/che-dashboard:${CHE_VERSION}"

    docker build -t ${containerURL} -f apache.Dockerfile .
    if [[ $? -ne 0 ]]; then
        die_with  "docker build of ${containerURL} image is failed!"
    fi

    echo y | docker push ${containerURL}
    if [[ $? -ne 0 ]]; then
        die_with  "docker push of ${containerURL} image is failed!"
    fi

    verifyContainerExistsWithTimeout ${containerURL} 30

    echo "[INFO] Workspace loader has been released"
}

releaseCheWorkspaceLoader()
{
    set -x

    cd che-workspace-loader
    containerURL="${REGISTRY}/${ORGANIZATION}/che-workspace-loader:${CHE_VERSION}"

    docker build -t ${containerURL} -f apache.Dockerfile .
    if [[ $? -ne 0 ]]; then
        die_with  "docker build of ${containerURL} image is failed!"
    fi

    echo y | docker push ${containerURL}
    if [[ $? -ne 0 ]]; then
        die_with  "docker push of ${containerURL} image is failed!"
    fi

    verifyContainerExistsWithTimeout ${containerURL} 30

    echo "[INFO] Workspace loader has been released"
}

releaseCheDocs() {
    tmpdir="$(mktemp -d)"
    pushd "${tmpdir}" >/dev/null || exit
    projectPath=eclipse/che-docs
    rm -f ./make-release.sh && curl -sSLO "https://raw.githubusercontent.com/${projectPath}/master/make-release.sh" && chmod +x ./make-release.sh
    ./make-release.sh --repo "git@github.com:${projectPath}" --version "${CHE_VERSION}" --trigger-release
    popd >/dev/null || exit 
}

releaseCheServer() {
    set -x
    if [[ $RELEASE_CHE_PARENT = "true" ]]; then
        cd che-parent
        mvn clean install -U -Pcodenvy-release -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE

        if [ $? -eq 0 ]; then
            echo 'Build Success!'
            echo 'Going to deploy artifacts'
            mvn clean deploy -Pcodenvy-release -DcreateChecksum=true -DautoReleaseAfterClose=$AUTORELEASE_ON_NEXUS -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE
            cd ..
        else
            echo 'Build Failed!'
            exit 1
        fi        
    fi

    cd che
    mvn clean install -U -Pcodenvy-release -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE

    if [ $? -eq 0 ]; then
        echo 'Build Success!'
        echo 'Going to deploy artifacts'
        mvn clean deploy -Pcodenvy-release -DcreateChecksum=true -DautoReleaseAfterClose=$AUTORELEASE_ON_NEXUS -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE
        cd ..
    else
        echo 'Build Failed!'
        exit 1
    fi
    set +x
}

# TODO ensure usage of respective bugfix branches
checkoutProjects() {
    pwd
    checkoutProject git@github.com:eclipse/che-parent
    checkoutProject git@github.com:eclipse/che
    checkoutProject git@github.com:eclipse/che-dashboard
    checkoutProject git@github.com:eclipse/che-workspace-loader
}

checkoutProject() {
    PROJECT="${1##*/}"
    echo "checking out project $PROJECT with ${BRANCH} branch"

    git clone $1
    cd $PROJECT
    git checkout ${BASEBRANCH}

    set -x
    if [[ "${BASEBRANCH}" != "${BRANCH}" ]]; then
        git branch "${BRANCH}" || git checkout "${BRANCH}" && git pull origin "${BRANCH}"
        git push origin "${BRANCH}"
        git fetch origin "${BRANCH}:${BRANCH}"
        git checkout "${BRANCH}"
    fi
    set +x
    cd ..

}

# TODO change it to someone else?
setupGitconfig() {
  git config --global user.name "Mykhailo Kuznietsov"
  git config --global user.email mkuznets@redhat.com

  # hub CLI configuration
  git config --global push.default matching
  export GITHUB_TOKEN=$CHE_BOT_GITHUB_TOKEN
}

createTags() {
    if [[ $RELEASE_CHE_PARENT = "true" ]]; then
        tagAndCommit che-parent
    fi
    tagAndCommit che-dashboard
    tagAndCommit che-workspace-loader
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
        docker rm -f $(docker ps -aq)
    fi

    # BUILD IMAGES
    for image_dir in ${DOCKER_FILES_LOCATIONS[@]}
      do
        if [[ ${image_dir} == "che/dockerfiles/che" ]]; then
          bash $(pwd)/${image_dir}/build.sh --tag:${TAG} --build-arg:"CHE_DASHBOARD_VERSION=${CHE_VERSION},CHE_WORKSPACE_LOADER_VERSION=${CHE_VERSION}"  
        else
          bash $(pwd)/${image_dir}/build.sh --tag:${TAG} 
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

loginQuay() {
    if [[ -n "${QUAY_ECLIPSE_CHE_USERNAME}" ]] && [[ -n "${QUAY_ECLIPSE_CHE_PASSWORD}" ]]; then
        docker login -u "${QUAY_ECLIPSE_CHE_USERNAME}" -p "${QUAY_ECLIPSE_CHE_PASSWORD}" "${REGISTRY}"
    else
        echo "Could not login, missing credentials for pushing to the '${ORGANIZATION}' organization"
        die_with  "failed to login on Quay!"
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
        cd che-parent
        git checkout $2
        #install previous version, in case it is not available in central repo
        #which is needed for dependent projects
        
        mvn clean install
        mvn versions:set -DgenerateBackupPoms=false -DnewVersion=${CHE_VERSION}
        mvn clean install
        commitChangeOrCreatePR ${CHE_VERSION} $2 "pr-${2}-to-${1}"
        cd ..
    fi

    cd che-dashboard
    git checkout $2
    npm --no-git-tag-version version ${1}
    commitChangeOrCreatePR $1 $2 "pr-${2}-to-${1}"
    cd ..

    cd che-workspace-loader
    git checkout $2
    if [[ $RELEASE_CHE_PARENT = "true" ]]; then
        mvn versions:update-parent -DgenerateBackupPoms=false -DallowSnapshots=true -DparentVersion=[${CHE_VERSION}]
    fi
    mvn versions:set -DgenerateBackupPoms=false -DallowSnapshots=true -DnewVersion=$1
    commitChangeOrCreatePR $1 $2 "pr-${2}-to-${1}"
    cd ..
    
    cd che
    git checkout $2
    if [[ $RELEASE_CHE_PARENT = "true" ]]; then
        mvn versions:update-parent -DgenerateBackupPoms=false -DallowSnapshots=true -DparentVersion=[${CHE_VERSION}]
    fi
    mvn versions:set -DgenerateBackupPoms=false -DallowSnapshots=true -DnewVersion=$1
    sed -i -e "s#<che.dashboard.version>.*<\/che.dashboard.version>#<che.dashboard.version>$1<\/che.dashboard.version>#" pom.xml
    sed -i -e "s#<che.version>.*<\/che.version>#<che.version>$1<\/che.version>#" pom.xml
    commitChangeOrCreatePR $1 $2 "pr-${2}-to-${1}"
    cd ..    
}

bumpImagesInXbranch() {
    cd che
    git checkout ${BRANCH}
    cd .ci
    ./set_tag_version_images_linux.sh ${CHE_VERSION}
    cd ..
    git commit -asm "Release version ${CHE_VERSION}"
    git push origin ${BRANCH}
}

prepareRelease() {

    if [[ $RELEASE_CHE_PARENT = "true" ]]; then
        cd che-parent
        #install previous version, in case it is not available in central repo
        #which is needed for dependent projects
        mvn clean install
        mvn versions:set -DgenerateBackupPoms=false -DnewVersion=${CHE_VERSION}
        mvn clean install
        mvn clean install
        mvn versions:set -DgenerateBackupPoms=false -DnewVersion=${CHE_VERSION}
        mvn clean install
        cd ..
    fi
    echo "[INFO] Che Parent version has been updated"
    
    cd che-dashboard
    npm --no-git-tag-version version ${CHE_VERSION}
    cd ..
    echo "[INFO] Che Dashboard version has been updated"

    cd che-workspace-loader
    if [[ $RELEASE_CHE_PARENT = "true" ]]; then
        mvn versions:update-parent -DgenerateBackupPoms=false -DallowSnapshots=false -DparentVersion=[${CHE_VERSION}]
    fi
    mvn versions:set -DgenerateBackupPoms=false -DallowSnapshots=false -DnewVersion=${CHE_VERSION}
    cd ..
    echo "[INFO] Che Workspace Loader version has been updated"

    cd che
    if [[ $RELEASE_CHE_PARENT = "true" ]]; then
        mvn versions:update-parent -DgenerateBackupPoms=false -DallowSnapshots=false -DparentVersion=[${CHE_VERSION}]
    fi
    mvn versions:set -DgenerateBackupPoms=false -DallowSnapshots=false -DnewVersion=${CHE_VERSION}
    echo "[INFO] Che Server version has been updated"

    # Replace dependencies in che-server parent
    sed -i -e "s#<che.dashboard.version>.*<\/che.dashboard.version>#<che.dashboard.version>${CHE_VERSION}<\/che.dashboard.version>#" pom.xml
    sed -i -e "s#<che.version>.*<\/che.version>#<che.version>${CHE_VERSION}<\/che.version>#" pom.xml
    echo "[INFO] Dependencies updated in che-server parent"

    # TODO more elegant way to execute these scripts
    cd .ci
    ./set_tag_version_images_linux.sh ${CHE_VERSION}
    echo "[INFO] Tag versions of images have been set in che-server"

    cd ../..
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
    set +x
    set -e
    export QUAY_USERNAME=$QUAY_ECLIPSE_CHE_USERNAME
    export QUAY_PASSWORD=$QUAY_ECLIPSE_CHE_PASSWORD

    export GIT_USER=mkuznyetsov
    export GIT_PASSWORD=none

    #preinstall operator-courier and operator-sdk
    pip3 install operator-courier==2.1.7
    pip3 install yq

    OP_SDK_DIR=/opt/operator-sdk
    mkdir -p $OP_SDK_DIR
    wget https://github.com/operator-framework/operator-sdk/releases/download/v0.10.0/operator-sdk-v0.10.0-x86_64-linux-gnu -O $OP_SDK_DIR/operator-sdk 
    chmod +x $OP_SDK_DIR/operator-sdk

    BASE32_UTIL_PATH=$(pwd)/utils
    # add base32 shortcut
    export PATH="$PATH:$OP_SDK_DIR:$BASE32_UTIL_PATH"

    git clone git@github.com:eclipse/che-operator.git
    cd che-operator

    echo "operator courier version"
    operator-courier --version

    git checkout ${BRANCH}
    ./make-release.sh ${CHE_VERSION} --release --release-olm-files
    git checkout ${CHE_VERSION}
    ./make-release.sh ${CHE_VERSION} --push-git-changes --pull-requests  
}

loadJenkinsVars
loadMvnSettingsGpgKey
installDeps
setupGitconfig

evaluateCheVariables

# release che-theia, machine-exec and devfile-registry
 { ./cico_release_theia_and_registries.sh ${CHE_VERSION} eclipse/che-theia            devtools-che-theia-che-release        90 & }; pid_1=$!;
 { ./cico_release_theia_and_registries.sh ${CHE_VERSION} eclipse/che-machine-exec     devtools-che-machine-exec-release     60 & }; pid_2=$!;
 { ./cico_release_theia_and_registries.sh ${CHE_VERSION} eclipse/che-devfile-registry devtools-che-devfile-registry-release 75 & }; pid_3=$!;
waitForPids $pid_1 $pid_2 $pid_3
wait
# then release plugin-registry (depends on che-theia and machine-exec)

 { ./cico_release_theia_and_registries.sh ${CHE_VERSION} eclipse/che-plugin-registry  devtools-che-plugin-registry-release  45 & }; pid_4=$!;
waitForPids $pid_4
wait

#release of che should start only when all necessary release images are available on Quay
checkoutProjects
prepareRelease
createTags

loginQuay

{ ./cico_release_dashboard_and_workspace_loader.sh "che-dashboard" "${REGISTRY}/${ORGANIZATION}/che-dashboard:${CHE_VERSION}" 40 & }; pid_5=$!;
{ ./cico_release_dashboard_and_workspace_loader.sh "che-workspace-loader" "${REGISTRY}/${ORGANIZATION}/che-workspace-loader:${CHE_VERSION}" 20 & }; pid_6=$!;
waitForPids $pid_5 $pid_6
wait

releaseCheDocs &
releaseCheServer
buildImages  ${CHE_VERSION}
tagLatestImages ${CHE_VERSION}
pushImagesOnQuay ${CHE_VERSION} pushLatest
bumpVersions
bumpImagesInXbranch

releaseOperator
