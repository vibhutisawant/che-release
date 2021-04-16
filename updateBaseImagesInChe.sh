#!/bin/bash

CLONE_PROJECTS=0

while [[ "$#" -gt 0 ]]; do	
  case $1 in	
    '-c'|'--clone') CLONE_PROJECTS=1; shift 0;;	
  esac	
  shift 1	
done	

updateImagesInProject() 
{
    this_project=$1
    this_branch=$2
    this_command=$3

    if [[ $CLONE_PROJECTS -eq 1 ]]; then	
        git clone https://github.com/$this_project
    fi

    cd ${this_project#*/}
    checkout $this_branch
    cd ..
    
    $this_command

}

updateImagesInProject "eclipse-che/che-machine-exec" "master" "" &
updateImagesInProject "eclipse-che/che-theia" "master" "" &
updateImagesInProject "eclipse/che-devfile-registry" "master" "" &
updateImagesInProject "eclipse/che-plugin-registry" "master" "" &
updateImagesInProject "eclipse-che/che-dashboard" "main" "" &
updateImagesInProject "che-incubator/chectl" "master" "" &
updateImagesInProject "eclipse/che" "master" "" &
updateImagesInProject "eclipse-che/che-operator" "master" "" &
wait
