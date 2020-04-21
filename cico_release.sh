load_jenkins_vars() {
    set +x
    eval "$(./env-toolkit load -f jenkins-env.json \
                              CHE_BOT_GITHUB_TOKEN \
                              CHE_GITHUB_SSH_KEY \
                              CHE_MAVEN_SETTINGS \
                              CHE_OSS_SONATYPE_GPG_KEY \
                              CHE_OSS_SONATYPE_PASSPHRASE)"
}

load_mvn_settings_gpg_key() {
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

install_deps(){
    set +x
    yum -q -y update
    yum -q -y install centos-release-scl-rh java-1.8.0-openjdk-devel git 
    yum -q -y install rh-maven33
}

evaluate_che_variables() {
    source VERSION
    echo "Che version: ${CHE_VERSION}"
    # derive branch from version
    BRANCH=${CHE_VERSION%.*}.x
    echo "Branch: ${BRANCH}"
}

build_and_deploy_artifacts() {
    set -x
    scl enable rh-maven33 'mvn clean install -U'
    if [ $? -eq 0 ]; then
        echo 'Build Success!'
        echo 'Going to deploy artifacts'
        scl enable rh-maven33 "mvn clean deploy -Pcodenvy-release -DcreateChecksum=true  -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE"

    else
        echo 'Build Failed!'
        exit 1
    fi
}

# TODO ensure usage of respective bugfix branches
prepare_projects() {
    pwd
    prepare_project git@github.com:eclipse/che-parent.git
    prepare_project git@github.com:eclipse/che-docs.git
    prepare_project git@github.com:eclipse/che.git

    # TODO UNCOMMENT FOR POST 7.10.x releases!!!
    #git clone git@github.com:eclipse/che-dashboard.git
    #git clone git@github.com:eclipse/che-workspace-loader.git
}

prepare_project() {
    echo "preparing project $1 with ${BRANCH} branch"
    git clone $1 --branch ${BRANCH}
}

# ensure proper version is used
apply_transformations() {
    #sed -i "/<\/parent>/i \ \ \ \ \ \ \ \ <relativePath>../che-parent/dependencies</relativePath>" che-dashboard/pom.xml che-docs/pom.xml che-workspace-loader/pom.xml che/pom.xml
    scl enable rh-maven33 "mvn versions:set -DgenerateBackupPoms=false -DnewVersion=${CHE_VERSION} -DprocessAllModules"
    mvn versions:set -DgenerateBackupPoms=false -DnewVersion=${CHE_VERSION} -DprocessAllModules

    #TODO more elegant way to execute this script
    DIR=pwd
    #TODO run .ci/set_tag_version_images image script
}

# TODO change it to something else?
setup_gitconfig() {
  git config --global user.name "Vitalii Parfonov"
  git config --global user.email vparfono@redhat.com
}

create_tags() {
    cd $1
    git tag "${CHE_VERSION}" || die_with "Failed to create tag ${CHE_VERSION}! Release has been deployed, however"
    git push --tags ||  die_with "Failed to push tags. Please do this manually"
    cd ..
}

 # KEEP RIGHT ORDER!!!
DOCKER_FILES_LOCATIONS=(
    dockerfiles/endpoint-watcher
    dockerfiles/keycloak
    dockerfiles/postgres
    dockerfiles/dev
    dockerfiles/che
    dockerfiles/dashboard-dev
    dockerfiles/e2e
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
         if [[ ${image_dir} == "dockerfiles/che" ]]; then
           #CENTOS SINGLE USER
           BUILD_ASSEMBLY_DIR=$(echo assembly/assembly-main/target/eclipse-che-*/eclipse-che-*/)
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

#load_jenkins_vars
#load_mvn_settings_gpg_key
#install_deps

evaluate_che_variables
prepare_projects
apply_transformations

#build_and_deploy_artifacts
#create_tags
#buildImages  ${CHE_VERSION}
#tagLatestImages ${CHE_VERSION}
#pushImagesOnQuay ${CHE_VERSION} pushLatest