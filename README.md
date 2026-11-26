# keypin-rotate

A GitHub Action that runs [keypin](https://github.com/caiopizzol/keypin) scheduled rotation with
[keypin.dev](https://keypin.dev). Each run:

1. Restores `.keypin/rotation.json` and `status.json` from the `keypin/state` branch.
2. Gets a GitHub token from keypin.dev, for keypin to publish keys to GitHub.
3. Revokes the old keys an approver approved on keypin.dev, if `.keypin/rotation.json` still names them.
4. Rotates every due key with `keypin rotate --due --yes`.
5. Saves the state to `keypin/state`, and keeps a copy as a 90-day artifact.
6. Tells keypin.dev which old keys wait, so it emails the approvers.

To rotate without keypin.dev, use the workflow in keypin's
[scheduled rotation guide](https://github.com/caiopizzol/keypin/blob/main/docs/guides/scheduled-rotation.md).

## Setup

You need:

- the keypin-app GitHub App installed on the repository, from keypin.dev
- approvers for the repository on keypin.dev
- an environment named `rotation`
- a 1Password service account token saved in `rotation` as the secret `OP_SERVICE_ACCOUNT_TOKEN`, as steps 1 to 3 of
  the [guide](https://github.com/caiopizzol/keypin/blob/main/docs/guides/scheduled-rotation.md#setup) say

Add this workflow as `.github/workflows/rotate-keys.yml` on the default branch. keypin.dev gives a token only to that
file, run on a schedule or by hand, in the `rotation` environment.

```yaml
name: Rotate keys
on:
  schedule: [{ cron: "17 9 * * *" }]
  workflow_dispatch:
    inputs:
      check_setup: { type: boolean, default: false, description: Check the setup, and rotate nothing }
permissions: {}
jobs:
  rotate:
    runs-on: ubuntu-latest
    environment: rotation
    concurrency: { group: rotate-keys, cancel-in-progress: false }
    permissions: { contents: write, id-token: write }
    steps:
      - uses: caiopizzol/keypin-rotate@<full commit SHA>
        with:
          op-service-account-token: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}
          check-setup: ${{ inputs.check_setup || false }}
```

Pin the action to a full commit SHA, not a tag: the action gets your 1Password token.

Then run the workflow with **check setup** checked. It runs `keypin rotate --check` and changes nothing.

## Inputs

| Input                      | Default        | Description                                                          |
| -------------------------- | -------------- | -------------------------------------------------------------------- |
| `op-service-account-token` |                | 1Password service account token. Required.                           |
| `check-setup`              | `false`        | `true` runs `keypin rotate --check`, and revokes and reports nothing. |
| `keypin-version`           | `0.46.1`       | Exact keypin version to install.                                     |
| `state-branch`             | `keypin/state` | Branch that keeps `.keypin/`.                                        |

## Outputs

| Output         | Description                                                                         |
| -------------- | ----------------------------------------------------------------------------------- |
| `state-commit` | Commit on the state branch after the run. Empty when the run had nothing to save. |

## State branch

If the state branch doesn't exist, the first run creates it, from `.keypin/` on the default branch if it's there. Once
the state branch exists, the run ignores `.keypin/` on the default branch. A
runner has no receipts of earlier publishes, so publish the first keys from your laptop, as step 8 of the
[guide](https://github.com/caiopizzol/keypin/blob/main/docs/guides/scheduled-rotation.md#setup) says.

The run pushes only if the state branch is still at the commit it restored. If something else pushed to it in the
meantime, the run fails and leaves the branch as it is. The run's state is then in the `keypin-state-<run id>-<attempt>`
artifact.
