This repo contains orchestration scripts for Eclipse Che artifacts and container images.

Job is https://ci.centos.org/job/devtools-che-release-che-release

Note that over time, this job, and all the jobs called by it, will be migrated to a GH action script.

# Che release process

# Phase 0 - permissions

1. Get push permission from @fbenoit to push applications
    * https://quay.io/organization/eclipse-che-operator-kubernetes/teams/pushers
    * https://quay.io/organization/eclipse-che-operator-openshift/teams/pushers 
    * https://quay.io/application/eclipse-che-operator-kubernetes
    * https://quay.io/application/eclipse-che-operator-openshift

2. Get commit rights from @fbenoit to push community PRs
    * https://github.com/che-incubator/community-operators

## Phase 1 - automated build steps

1. [Create new release issue to report status and collect any blocking issues](https://github.com/eclipse/che/issues/new?assignees=&labels=kind%2Frelease&template=release.md&title=Release+Che+7.FIXME)
1. Update `VERSION` file in che-release repo's release branch, including enabling the PHASES (currently 1 - 7)
1. Push commit to `release` branch (with `-f` force if needed)
1. Wait until https://ci.centos.org/job/devtools-che-release-che-release/ completes (2-3 hrs)

    TODO: add notification when build is done - email? slack? mattermost?

1. NOTE: If the build should fail, check log for which step crashed (eg., due to [rate limiting](https://github.com/eclipse/che/issues/18292) or other errors), like E2E test failures. Sometimes simply re-running will help.

1. To skip sections which have completed successfully, simply remove `PHASES` from the `VERSION` file and commit that change to the `release` branch to trigger the parts of the release that were not successful.

## Phase 2 - manual steps

### community operators

TODO: [move this step into a GH action](https://github.com/eclipse/che-operator/pull/572). 
TODO: set up the above action to fire when a PR like https://github.com/eclipse/che-operator/pull/571/files is merged, eg., 
    when:
        olm/eclipse-che-preview-openshift/deploy/olm-catalog/eclipse-che-preview-openshift/eclipse-che-preview-openshift.package.yaml and 
        olm/eclipse-che-preview-kubernetes/deploy/olm-catalog/eclipse-che-preview-kubernetes/eclipse-che-preview-kubernetes.package.yaml 
    are updated

This depends on the che-operator PRs being merged.

1. Prepare for creation of community operator PRs via script in https://github.com/eclipse/che-operator (*ONLY after ALL PRs* for che-operator and chectl are merged):

        ./olm/prepare-community-operators-update.sh

1. Once created you'll see our PRs here:
    * https://github.com/operator-framework/community-operators/pulls?q=%22Update+eclipse-che+operator%22+is%3Aopen

1. If tests fail or community operator PRs get stalled:
            * Ping @j0zi (Jozef Breza) or @mavala (Martin Vala)

1. After creating the PRs, add a link to the new PRs from the release issue, eg.,
    * https://github.com/eclipse/che/issues/18468 -> 
    * https://github.com/operator-framework/community-operators/pulls?q=is%3Apr+7.23.0


### chectl

TODO: set GH action to trigger when community PRs are merged? Can we trigger across repos? See problem in https://github.com/eclipse/che/issues/18627


This depends on the che-operator PRs being merged (but not the community PRs).

1. Run this action: https://github.com/che-incubator/chectl/actions?query=workflow%3A%22Release+-+create+pull+request+for+upcoming+release%22

1. Find the generated PR: https://github.com/che-incubator/chectl/pulls?q=is%3Apr+author%3Aapp%2Fgithub-actions+%22Release+version%22+is%3Aopen

1. Once approved / tests passed / known failures overridden, commit the PR, eg., https://github.com/che-incubator/chectl/pull/1021

1. This second action should run automatically on commit of the above PR: https://github.com/che-incubator/chectl/actions?query=workflow%3A%22Release+-+generate%20release%20and%20push%20artifacts%20to%20github%20pages%20(after%20PR%20approved)%22

--------------

# Che release gotchas

* VERSION file - should we add a test to verify we're not trying to re-release an existing release w/o an explicit override?

* add step to delete existing tag if exists and need to re-run a step (eg., broken theia needs a re-release of `:7.y.z+1`)

* can run `make-release.sh` for chectl before operator PRs are merged? does it make sense to create the GH release BEFORE we run the make-release script?

* add notification (email? UMB? slack?) when che-release job is done?
