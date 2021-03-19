This repo contains orchestration scripts for Eclipse Che artifacts and container images.

Job is https://ci.centos.org/job/devtools-che-release-che-release

Note that over time, this job, and all the jobs called by it, will be migrated to a GH action script.

# Che release process

## Automated release workflows

Currently all projects have automated release process, that consists of GitHub Actions workflow.
Additionally, release logic is mostly contained within `make-release.sh` file, which allows to perform the release outside of GitHub Actions framework, should the need for it arises.
For example, In [Che server](https://github.com/eclipse/che) we have [release.yml](https://github.com/eclipse/che/actions/workflows/release.yml) GitHub acitons workflow, which also makes [make-release.sh](https://github.com/eclipse/che/blob/master/make-release.sh) release script

GitHub Actions release workflows are currently allowed to be run by any user, who has write permissions to the repository, in which the workflow is located. They also utilize repository secrets, such as Quay or Docker.io credentials, that are required by most of the release workflows, as should be provided manually, when used standalone `make-release.sh`.

## Projects overview
Most of the projects that are part of the weekly release cycle are also united in this project's workflow - the [Release - Orchestrate Overall Release Phases](https://github.com/eclipse/che-release/actions?query=workflow%3A%22Release+-+Orchestrate+Overall+Release+Phases%22)
With the exception of some projects, it allows to perform the bulk of the release process with 1 click, running following projects in the correct order, making them complete a full release process - pushing commits or pull request to respective repositories, deploying artifacts etc. The projects that are covered by this workflow are:
- [che-machine-exec](https://github.com/eclipse-che/che-machine-exec) - release artifact is the [eclipse/che-machine-exec](https://quay.io/repository/eclipse/che-machine-exec?tab=tags) container image
- [che-theia](https://github.com/eclipse/che-theia) - release artifacts are several container images - [theia-dev](https://quay.io/repository/eclipse/che-theia-dev?tab=tags), [che-theia](https://quay.io/repository/eclipse/che-theia?tab=tags) and [che-theia-endpoint-runtime-binary](https://quay.io/repository/eclipse/che-theia-endpoint-runtime-binary?tab=tags)
- [che-devfile-registry](https://github.com/eclipse/che-devfile-registry) - release artifact is the [eclipse/che-devfile-registry](https://quay.io/repository/eclipse/che-devfile-registry?tab=tags) container image
- [che-plugin-registry](https://github.com/eclipse/che-plugin-registry) - release artifact is the [eclipse/che-plugin-registry](https://quay.io/repository/eclipse/che-plugin-registry?tab=tags) container image
- [che-dashboard](https://github.com/eclipse/che-dashboard) - release artifacts is the [eclipse/che-dashboard](https://quay.io/repository/eclipse/che-dashboard?tab=tags) container image
- [che-operator](https://github.com/eclipse-che/che-operator) - release artifacts is the [eclipse/che-operator](https://quay.io/repository/eclipse/che-operator?tab=tags) container image. Hovewer, the release has to completed manually, which will
- [che-jwtproxy](https://github.com/eclipse/che-jwtproxy) - no actual release, only create a corresponding bugfix branch
- [kubernetes-image-puller](https://github.com/che-incubator/kubernetes-image-puller) - no actual release, only create a corresponding bugfix branch
- [devworkspace-operator](https://github.com/devfile/devworkspace-operator) - release artifact is the [devfile/devworkspace-controller](https://quay.io/repository/devfile/devworkspace-controller?tab=tags) container image
- [devworkspace-che-operator](https://github.com/che-incubator/devworkspace-che-operator) - release artifact is the [che-incubator/devworkspace-controller](https://quay.io/repository/devfile/devworkspace-controller?tab=tags) container image
- [che](https://github.com/eclipse/che) - release artifacts are maven artifacts for Che server, as well as several container images:
    [quay.io/eclipse/che-endpoint-watcher](https://quay.io/repository/eclipse/che-endpoint-watcher?tab=tags),
    [quay.io/eclipse/che-keycloak](https://quay.io/repository/eclipse/che-keycloak?tab=tags),
    [quay.io/eclipse/che-postgres](https://quay.io/repository/eclipse/che-postgres?tab=tags),
    [quay.io/eclipse/che-dev](https://quay.io/repository/eclipse/che-dev?tab=tags),
    [quay.io/eclipse/che-server](https://quay.io/repository/eclipse/che-server?tab=tags),
    [quay.io/eclipse/che-dashboard-dev](https://quay.io/repository/eclipse/che-dashboard-dev?tab=tags) and
    [quay.io/eclipse/che-e2e](https://quay.io/repository/eclipse/che-e2e?tab=tags)

In the case of Che Operator, as well as workflows that depend on it - chectl, che-docs and community-operator PR generation. This is due to performing manual verifications in Che Operator by the Deploy team (and also various tests run against running Che, so we have a chance to see if it functions). When everything has been verified, after the merging of operator PRs the following projects workflows will be triggered automatically.
- [chectl](https://github.com/che-incubator/chectl - release arifact is binary, which is also published on [Releases page]https://github.com/che-incubator/chectl/releases 
- [che-docs](https://github.com/eclipse/che-docs) - only create tag and pull request to update to latest released version of Che
- [community-operator](https://github.com/operator-framework/community-operators/) - create pull requests to https://github.com/operator-framework/community-operators/pulls?q=%22Update+eclipse-che+operator%22+is%3Aopen to update to latest released version of Che

## Release phases

At the moment, [Release - Orchestrate Overall Release Phases]((https://github.com/eclipse/che-release/actions?query=workflow%3A%22Release+-+Orchestrate+Overall+Release+Phases%22)) job has the way of ordering the release by utilizing the concept of phases.
Currently there are several phases, representing an order of projects, which we can execute in parallel, as long as their dependent projects have been released. Projects in lower phases are those, on which projects from higher phase will depend.
Phase 1 - [che-devfile-registry](https://github.com/eclipse/che-devfile-registry), [che-theia](https://github.com/eclipse/che-theia), [che-machine-exec](https://github.com/eclipse-che/che-machine-exec), [che-jwt-proxy](https://github.com/eclipse/che-jwtproxy), [kubernetes-image-puller](https://github.com/che-incubator/kubernetes-image-puller), [devworkspace-operator](https://github.com/devfile/devworkspace-operator), [che-dashboard](https://github.com/eclipse/che-dashboard)
Phase 2 - [che-plugin-registry](https://github.com/eclipse/che-plugin-registry) - depends on [che-theia](https://github.com/eclipse/che-theia)
Phase 3 - [che](https://github.com/eclipse/che) - depends on - [che-dashboard](https://github.com/eclipse/che-dashboard)
Phase 4 - [devworkspace-che-operator](https://github.com/che-incubator/devworkspace-che-operator) - depends on [devworkspace-operator](https://github.com/devfile/devworkspace-operator)
Phase 5 - [che-operator](https://github.com/eclipse-che/che-operator) - depends on everything from phase 1 to 4

Phases list is a comma separated list (default, which includes all phases "1,2,3,4,5"). Removing certain phases is useful, when you rerun the orchestration job, and certain projects shouldn't be released again. 
Note that this approach will change, once a new system will be implemented, where we can more clearly specify dependencies between workflows, using special types of GitHub action.


## Release procedure
1. [Create new release issue to report status and collect any blocking issues](https://github.com/eclipse/che/issues/new?assignees=&labels=kind%2Frelease&template=release.md&title=Release+Che+7.FIXME)

2. To start a release, use the [Release - Orchestrate Overall Release Phases] workflow to begin with releasing . In the input, you have to provide the version of Che, DevWorkspace controller, and phases. 

2.1 If one of the workflows has crashed, inspect it. Apply fixes if needed, and restart it. You can restart individual workflow, or whole phase in orchestration job, whichever is simpler.
2.2 Keep in mind, that sometimes you'll need to regenerate tags, or skip certain substeps in that job. Also ensure that correct code is in place, whether it is main or bugfix branch.
2.3 Sometimes, the hotfix changes to the workflow can take too long to get approved and merged. In certain situations, we can use the modified workflow file, which is pushed in its own branch, and then trigger the workflow, while specifying the branch with our modified workflow. 

3. When Che Operator PRs have been generated, you must wait for the approval of PR checks, that are in that repository. If there are any questions, you can forward them to the check maintaners (Deploy team). When PRs are merged, the last batch of projects will be triggered to release
3.1 Chectl PR has to be closed manually, after they're generated, and all its associated PR checks are passed.
3.2 Community operator PRs are merged by Operator Framework members, as soon as their tests will pass (in some cases they may require some input from us)
3.3 Docs PR has to be merged by Docs team.

4. If the release is complete, send an e-mail to `che-dev` mailing list, about succesful release.

--------------


# Che release gotchas

* VERSION file - should we add a test to verify we're not trying to re-release an existing release w/o an explicit override?