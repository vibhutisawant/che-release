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

build_and_deploy_artifacts() {
    set -x
    scl enable rh-maven33 'mvn clean install -U'
    if [ $? -eq 0 ]; then
        echo 'Build Success!'
        echo 'Going to deploy artifacts'
        scl enable rh-maven33 "mvn clean install -Pcodenvy-release -DcreateChecksum=true  -Dgpg.passphrase=$CHE_OSS_SONATYPE_PASSPHRASE"

    else
        echo 'Build Failed!'
        exit 1
    fi
}

# TODO ensure usage of respective bugfix branches
prepare_projects() {
    pwd
    git clone git@github.com:eclipse/che-parent.git
    git clone git@github.com:eclipse/che-dashboard.git
    git clone git@github.com:eclipse/che-workspace-loader.git
    git clone git@github.com:eclipse/che-docs.git
    git clone git@github.com:eclipse/che.git
}

# ensure proper version is used
apply_transformations() {
    sed -i "/<\/parent>/i \ \ \ \ \ \ \ \ <relativePath>../che-parent/dependencies</relativePath>" che-dashboard/pom.xml che-docs/pom.xml che-workspace-loader/pom.xml che/pom.xml
    scl enable rh-maven33 "mvn versions:set -DgenerateBackupPoms=false -DnewVersion=7.10.1 -DprocessAllModules"
}

load_jenkins_vars
load_mvn_settings_gpg_key
install_deps
prepare_projects
apply_transformations
build_and_deploy_artifacts