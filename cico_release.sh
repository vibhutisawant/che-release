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
    yum -y install centos-release-scl-rh java-1.8.0-openjdk-devel git skopeo
    yum -y install rh-maven33
    yum install -y yum-utils device-mapper-persistent-data lvm2
    yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    curl -sL https://rpm.nodesource.com/setup_10.x | bash -
    yum-config-manager --add-repo https://dl.yarnpkg.com/rpm/yarn.repo
    yum install -y docker-ce nodejs yarn gcc-c++ make jq hub
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
}

releaseCheDashboard()
{
    set -x
    cd che-dashboard
    docker build -t ${REGISTRY}/${ORGANIZATION}/che-dashboard:${CHE_VERSION} -f apache.Dockerfile .
    echo y | docker push ${REGISTRY}/${ORGANIZATION}/che-dashboard:${CHE_VERSION}
    containerURL="quay.io/eclipse/che-dashboard:${CHE_VERSION}"

    echo "${containerURL}"
    verifyContainerExistsWithTimeout ${containerURL} 30

    echo "[INFO] Workspace loader has been released"
    
    cd ..
    set +x
}

releaseCheWorkspaceLoader()
{
    set -x
    cd che-workspace-loader
    docker build -t ${REGISTRY}/${ORGANIZATION}/che-workspace-loader:${CHE_VERSION} -f apache.Dockerfile .
    echo y | docker push ${REGISTRY}/${ORGANIZATION}/che-workspace-loader:${CHE_VERSION}
    containerURL="quay.io/eclipse/che-dashboard:${CHE_VERSION}"

    echo "${containerURL}"
    verifyContainerExistsWithTimeout ${containerURL} 30

    echo "[INFO] Workspace loader has been released"
    cd ..
    set +x
}

releaseCheServer() {
    echo "test"
    set -x
    cd che-parent
    scl enable rh-maven33 "mvn clean install -U -Pcodenvy-release -DskipTests=true -Dskip-validate-sources  -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE"

    if [ $? -eq 0 ]; then
        echo 'Build Success!'
        echo 'Going to deploy artifacts'
        scl enable rh-maven33 "mvn clean deploy -Pcodenvy-release -DcreateChecksum=true -DskipTests=true -Dskip-validate-sources -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE"
        cd ..
    else
        echo 'Build Failed!'
        exit 1
    fi
    cd ..
    
    cd che
    scl enable rh-maven33 "mvn clean install -U -Pcodenvy-release -DskipTests=true -Dskip-validate-sources  -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE"

    if [ $? -eq 0 ]; then
        echo 'Build Success!'
        echo 'Going to deploy artifacts'
        scl enable rh-maven33 "mvn clean deploy -Pcodenvy-release -DcreateChecksum=true -DskipTests=true -Dskip-validate-sources -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE"
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
}

createTags() {
    tagAndCommit che-parent
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
         bash $(pwd)/${image_dir}/build.sh --tag:${TAG} 
         if [[ ${image_dir} == "che/dockerfiles/che" ]]; then
           #CENTOS SINGLE USER
           BUILD_ASSEMBLY_DIR=$(echo che/assembly/assembly-main/target/eclipse-che-*/eclipse-che-*/)
           LOCAL_ASSEMBLY_DIR="${image_dir}/eclipse-che"
           if [[ -d "${LOCAL_ASSEMBLY_DIR}" ]]; then
               rm -r "${LOCAL_ASSEMBLY_DIR}"
           fi
           cp -r "${BUILD_ASSEMBLY_DIR}" "${LOCAL_ASSEMBLY_DIR}"
           docker build -t ${REGISTRY}/${ORGANIZATION}/che-server:${TAG}-centos -f $(pwd)/${image_dir}/Dockerfile.centos $(pwd)/${image_dir}/
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
         if [[ ${image} == "${REGISTRY}/${ORGANIZATION}/che-server" ]]; then
           docker tag "${image}:$1-centos" "${image}:latest-centos"
         fi
         if [[ $? -ne 0 ]]; then
           die_with  "docker tag of '${image}' image is failed!"
         fi
     done
}

pushImagesOnQuay() {
    #PUSH IMAGES
      if [[ -n "${QUAY_ECLIPSE_CHE_USERNAME}" ]] && [[ -n "${QUAY_ECLIPSE_CHE_PASSWORD}" ]]; then
        docker login -u "${QUAY_ECLIPSE_CHE_USERNAME}" -p "${QUAY_ECLIPSE_CHE_PASSWORD}" "${REGISTRY}"
    else
        echo "Could not login, missing credentials for pushing to the '${ORGANIZATION}' organization"
         return
    fi
    for image in ${IMAGES_LIST[@]}
        do
            echo y | docker push "${image}:$1"
            if [[ $2 == "pushLatest" ]]; then
                echo y | docker push "${image}:latest"
            fi
            if [[ ${image} == "${REGISTRY}/${ORGANIZATION}/che-server" ]]; then
                if [[ $2 == "pushLatest" ]]; then
                echo y | docker push "${REGISTRY}/${ORGANIZATION}/che-server:latest-centos"
                fi
            echo y | docker push "${REGISTRY}/${ORGANIZATION}/che-server:$1-centos"
            fi
            if [[ $? -ne 0 ]]; then
            die_with  "docker push of '${image}' image is failed!"
            fi
        done
}

commitChangeOrCreatePR() {
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
        #lastCommitComment="$(git log -1 --pretty=%B)"
        #hub pull-request -o -f -m "${lastCommitComment} ${lastCommitComment}" -b "${aBRANCH}" -h "${PR_BRANCH}"
    fi
}

bumpVersion() {
    set -x

    cd che-parent
    git checkout $2

    echo "[info]bumping to version $1 in branch $2"

    # install previous version, in case it is not available in central repo
    # which is needed for dependent projects
    
    scl enable rh-maven33 "mvn clean install"
    scl enable rh-maven33 "mvn versions:set -DgenerateBackupPoms=false -DnewVersion=$1"
    scl enable rh-maven33 "mvn clean install"
    commitChangeOrCreatePR $1 $2 "pr-${2}-to-${1}"
    cd ..

    cd che-dashboard
    git checkout $2
    scl enable rh-maven33 "mvn versions:update-parent -DgenerateBackupPoms=false -DallowSnapshots=true -DparentVersion=[$1]"
    scl enable rh-maven33 "mvn versions:set -DgenerateBackupPoms=false -DallowSnapshots=true -DnewVersion=$1"
    commitChangeOrCreatePR $1 $2 "pr-${2}-to-${1}"
    cd ..

    cd che-workspace-loader
    git checkout $2
    scl enable rh-maven33 "mvn versions:update-parent -DgenerateBackupPoms=false -DallowSnapshots=true -DparentVersion=[$1]"
    scl enable rh-maven33 "mvn versions:set -DgenerateBackupPoms=false -DallowSnapshots=true -DnewVersion=$1"
    commitChangeOrCreatePR $1 $2 "pr-${2}-to-${1}"
    cd ..
    
    cd che
    git checkout $2
    scl enable rh-maven33 "mvn versions:update-parent -DgenerateBackupPoms=false -DallowSnapshots=true -DparentVersion=[$1]"
    scl enable rh-maven33 "mvn versions:set -DgenerateBackupPoms=false -DallowSnapshots=true -DnewVersion=$1"
    sed -i -e "s#<che.dashboard.version>.*<\/che.dashboard.version>#<che.dashboard.version>$1<\/che.dashboard.version>#" pom.xml
    sed -i -e "s#<che.version>.*<\/che.version>#<che.version>$1<\/che.version>#" pom.xml
    commitChangeOrCreatePR $1 $2 "pr-${2}-to-${1}"
    cd ..    
}

prepareRelease() {
    cd che-parent
    # install previous version, in case it is not available in central repo
    # which is needed for dependent projects
    scl enable rh-maven33 "mvn clean install"
    scl enable rh-maven33 "mvn versions:set -DgenerateBackupPoms=false -DnewVersion=${CHE_VERSION}"
    scl enable rh-maven33 "mvn clean install"
    #mvn clean install
    #mvn versions:set -DgenerateBackupPoms=false -DnewVersion=${CHE_VERSION}
    #mvn clean install
    cd ..
    
    echo "[INFO] Che Parent version has been updated"
    
    cd che-dashboard
    scl enable rh-maven33 "mvn versions:update-parent -DgenerateBackupPoms=false -DallowSnapshots=true -DparentVersion=[${CHE_VERSION}]"
    scl enable rh-maven33 "mvn versions:set -DgenerateBackupPoms=false -DallowSnapshots=true -DnewVersion=${CHE_VERSION}"
    #mvn versions:update-parent -DgenerateBackupPoms=false -DallowSnapshots=true -DparentVersion=[${CHE_VERSION}]
    #mvn versions:set -DgenerateBackupPoms=false -DallowSnapshots=true -DnewVersion=${CHE_VERSION}
    cd ..

    echo "[INFO] Che Dashboard version has been updated"

    cd che-workspace-loader
    scl enable rh-maven33 "mvn versions:update-parent -DgenerateBackupPoms=false -DallowSnapshots=true -DparentVersion=[${CHE_VERSION}]"
    scl enable rh-maven33 "mvn versions:set -DgenerateBackupPoms=false -DallowSnapshots=true -DnewVersion=${CHE_VERSION}"
    #mvn versions:update-parent -DgenerateBackupPoms=false -DallowSnapshots=true -DparentVersion=[${CHE_VERSION}]
    #mvn versions:set -DgenerateBackupPoms=false -DallowSnapshots=true -DnewVersion=${CHE_VERSION}
    cd ..
    
    echo "[INFO] Che Workspace Loader version has been updated"

    cd che
    scl enable rh-maven33 "mvn versions:update-parent -DgenerateBackupPoms=false -DallowSnapshots=true -DparentVersion=[${CHE_VERSION}]"
    scl enable rh-maven33 "mvn versions:set -DgenerateBackupPoms=false -DallowSnapshots=true -DnewVersion=${CHE_VERSION}"
    #mvn versions:update-parent -DgenerateBackupPoms=false -DallowSnapshots=true -DparentVersion=[${CHE_VERSION}]
    #mvn versions:set -DgenerateBackupPoms=false -DallowSnapshots=true -DnewVersion=${CHE_VERSION}

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

loadJenkinsVars
loadMvnSettingsGpgKey
installDeps
setupGitconfig

evaluateCheVariables

# release che-theia, machine-exec and devfile-registry
./cico_release_theia_and_registries.sh ${CHE_VERSION} eclipse/che-theia            devtools-che-theia-che-release        90 &
./cico_release_theia_and_registries.sh ${CHE_VERSION} eclipse/che-machine-exec     devtools-che-machine-exec-release     60 &
./cico_release_theia_and_registries.sh ${CHE_VERSION} eclipse/che-devfile-registry devtools-che-devfile-registry-release 75 &
wait
# then release plugin-registry (depends on che-theia and machine-exec)
./cico_release_theia_and_registries.sh ${CHE_VERSION} eclipse/che-plugin-registry  devtools-che-plugin-registry-release  45 &
wait

# release of che should start only when all necessary release images are available on Quay
checkoutProjects
prepareRelease
createTags

releaseCheDashboard &
releaseCheWorkspaceLoader &
wait

releaseCheServer
buildImages  ${CHE_VERSION}
tagLatestImages ${CHE_VERSION}
pushImagesOnQuay ${CHE_VERSION} pushLatest

bumpVersions
