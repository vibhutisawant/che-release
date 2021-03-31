#!/bin/bash

updateImagesInProject() 
{
    this_project=$1
    this_branch=$2
    this_command=$3
    
    git clone https://github.com/$this_project
    cd $this_project
    checkout $this_branch
    cd ..
    
    $this_command

}

updateImagesInProject "eclipse/che-machine-exec" "master" "" &
updateImagesInProject "eclipse/che-theia" "master" "" &
updateImagesInProject "eclipse/che-devfile-registry" "master" "" &
updateImagesInProject "eclipse/che-plugin-registry" "master" "" &
updateImagesInProject "eclipse/che-" "master" "" &
updateImagesInProject "eclipse/che" "master" "" &
wait
