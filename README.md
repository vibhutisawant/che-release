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

1. Create new release issue to collect blocker issues (if any)
1. Update `VERSION` file in che-release repo's release branch
1. Check `cico_release.sh` script is properly set up (no important steps commented out from previous partial run)
1. Push commit to `release` branch (with `-f` force if needed)
1. Watch https://ci.centos.org/job/devtools-che-release-che-release/ for ~2hrs

1. NOTE: If the build should fail, check log for which step crashed (eg., due to [rate limiting](https://github.com/eclipse/che/issues/18292) or other errors). Comment out the parts of `cico_release.sh` script that completed successfully, and force push a new commit to the `release` branch to trigger the build again.

## Phase 2 - manual steps

### che-operator

    NOTE: this step will not be required once the che-operator release can push the CSV/OLM files automatically. See https://github.com/eclipse/che/issues/18393

1. When che-operator PRs are created, manually do this step to create new CSVs so that update tests will succeed on the che-operator PRs:
```
    export QUAY_ECLIPSE_CHE_USERNAME=[your quay user]
    export QUAY_ECLIPSE_CHE_PASSWORD=[your quay password or token]

    # DOESN'T WORK ON CENTOS CI, has to be done manually after PR generation
    CHE_VERSION=7.22.0

    pushd /tmp >/dev/null
      git clone git@github.com:eclipse/che-operator.git || true
      pushd che-operator >/dev/null
        # check out the correct che-operator branch
        git checkout ${CHE_VERSION}-release 

        # push the olm files
        ./make-release.sh ${CHE_VERSION} --push-olm-files
      popd >/dev/null
    popd >/dev/null
    rm -fr /tmp/che-operator
    
    # Note: this should be moved to GH action so it can happen more easily
```
(if this fails, check permissions above)


2. Manually re-trigger PR checks on 2 `che-operator` PRs (one for master, one for .x branch), eg., for 7.22.0, find PRs using query: https://github.com/eclipse/che-operator/pulls?q=is%3Apr+is%3Aopen+7.22.0
    * https://github.com/eclipse/che-operator/pull/548
    * https://github.com/eclipse/che-operator/pull/549
    
    * TODO: via GH API, send "/retest" to the PRs to retrigger the prow jobs.
    * TODO: figure out how to retrigger the other 'minikube' 'update' tests automatically (2 per PR)

    If anything goes wrong, check with Anatolii or Flavius for manual checks / failure overrides

1. Push operator PRs when checks have completed and they're approved 


### chectl

1. export your GH token to use with next step (creating PRs w/ `hub`)

1. Manually run https://github.com/che-incubator/chectl `make-release.sh` script; watch for update to https://github.com/che-incubator/chectl/releases

1. Push chectl PRs when approved
    * eg., https://github.com/che-incubator/chectl/pull/975


### community operators

1. Prepare for creation of community operator PRs via script in https://github.com/eclipse/che-operator (ONLY after ALL PRs are merged):
    `./olm/prepare-community-operators-update.sh`

    * (if this fails, check permissions above)

8. Create PRs using template https://github.com/operator-framework/community-operators/blob/master/docs/pull_request_template.md
    * https://github.com/operator-framework/community-operators/pulls?q=7.21.0
    * https://github.com/operator-framework/community-operators/pulls?q=%22Update+eclipse-che+operator%22

    * When you run the community operator update script, you'll see in the output links like these after branch is pushed
        ```
        remote: Create a pull request for 'update-eclipse-che-operator-7.21.1' on GitHub by visiting:
        remote:      https://github.com/che-incubator/community-operators/pull/new/update-eclipse-che-operator-7.21.1
        ```
        Then in the PR template, check all the checkboxes, but remove this section:
        ```
        ### New Submissions
        * [ ] Does your operator have [nested directory structure](https://github.com/operator-framework/community-operators/blob/master/docs/contributing.md#create-a-bundle)?
        * [ ] Have you selected the Project *Community Operator Submissions* in your PR on the right-hand menu bar?
        * [ ] Are you familiar with our [contribution guidelines](https://github.com/operator-framework/community-operators/blob/master/docs/contributing.md)?
        * [ ] Have you [packaged and deployed](https://github.com/operator-framework/community-operators/blob/master/docs/testing-operators.md) your Operator for Operator Framework?
        * [ ] Have you tested your Operator with all Custom Resource Definitions?
        * [ ] Have you tested your Operator in all supported [installation modes](https://github.com/operator-framework/operator-lifecycle-manager/blob/master/doc/design/building-your-csv.md#operator-metadata)?
        * [ ] Is your submission [signed](https://github.com/operator-framework/community-operators/blob/master/docs/contributing.md#sign-your-work)?
        ```

        Then comment in the issue; it will be closed after community update PRs are merged https://github.com/eclipse/che/issues/18296
        
        If tests fail or community operator PRs get stalled:
            * Ping @j0zi (Jozef Breza) or @mavala (Martin Vala)

--------------


# Che release gotchas

* VERSION file - should we add a test to verify we're not trying to re-release an existing release w/o an explicit override?

* add step to delete existing tag if exists and need to re-run a step (eg., broken theia needs a re-release of `:7.20.1`)

* `releaseCheServer` vs. `buildCheServer` - use boolean param vs. having to rememeber to toggle two different method names

* `./make-release.sh --push-olm-files` has to be run separately, then PR checks retriggered (maybe this will go away when we move to GH action).

* can run `make-release.sh` for chectl before operator PRs are merged? 

* add notification (email? UMB? slack?) when che-release job is done?