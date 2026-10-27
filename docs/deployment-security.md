# Deployment security

Antigravity-CI separates signing, review, and publication into distinct trust domains. A production deployment should use three different Windows runner identities and deployment-specific labels so a review process cannot inherit signing or publisher authority.

## Signing runner

The signing runner owns the only private signing key. Keep the private key on the machine and load it through the Windows OpenSSH agent; do not place the private key or its passphrase in GitHub secrets. The workflow receives only the public-key path plus a dedicated branch-update credential. The write credential is scoped to the signing step and is not persisted by checkout.

## Review runner

The review runner receives only a public copy of the trusted signing key. It must not have access to the signing account, SSH agent, publisher credential, or GitHub write credentials. Production deployments should prefer an ephemeral self-hosted review runner so one job receives a clean machine state. GitHub explicitly warns that persistent self-hosted runners can be persistently compromised by untrusted workflow code and recommends ephemeral runners for autoscaling.

For an initial persistent Windows pilot, use a dedicated low-privilege Windows account, a dedicated runner label, the sandbox smoke test, workspace cleanup, capability ceilings, and the Windows kill-on-close process job. These controls are defense in depth; they do not turn a persistent runner into an ephemeral isolation boundary.

## Publisher runner

The publisher runner must use a third OS identity and must not check out reviewed PR code. Prefer a dedicated GitHub App installation token. The App should be installed only on intended repositories and have the minimum repository permission needed to create and manage the timeline comment: either Issues write or Pull requests write. Metadata read is implicit for installed Apps. The workflow also verifies the actual account that created the comment.

The fallback reporter token exists for initial deployments only. Do not reuse the signing branch-update credential as the reporter token.

## Repository integration

Use an exact 40-character Antigravity-CI commit SHA in every caller workflow. Do not call a branch or moving tag. The project configuration in `.agy/project.toml` is a privileged policy input; review preparation reads it from the trusted base commit, never from the pull-request head.

Generate an initial caller with `scripts/New-AntigravityCaller.ps1` and an initial project config with `scripts/New-ProjectConfig.ps1`. Review the generated files before committing them to a target repository.

The reusable workflow rejects forks, draft pull requests, non-default target branches, repository-ID mismatches, and unapproved pull-request actions before allocating the signing runner. The same checks are repeated inside trusted PowerShell code.

## Fresh-turn boundary

A successful AGY report is an output, not permission to continue modifying the pull request. Publication ends the automated turn. A fresh owner/user turn is required before ChatGPT consumes the report, applies fixes, or merges.
