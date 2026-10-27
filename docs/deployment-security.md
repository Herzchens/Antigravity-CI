# Deployment security

Antigravity-CI separates signing, review, and publication into distinct trust domains. A production deployment should use three different Windows runner identities and deployment-specific labels so a review process cannot inherit signing or publisher authority.

## Signing runner

Every privileged job first replaces system/global Git configuration with a fresh per-job isolation file, an empty hooks directory, an empty global attributes file, and an empty Git template directory. This happens before any checkout. The signing gate selects the SSH signing key explicitly; it does not depend on user-level `gpg.format`, `gpg.ssh.program`, or `user.signingkey` configuration.

The signing runner owns the only private signing key. Keep the private key on the machine and load it through the Windows OpenSSH agent; do not place the private key or its passphrase in GitHub secrets. The workflow receives only the public-key path plus a dedicated branch-update credential. The write credential is scoped to the signing step and is not persisted by checkout.

Run the signing runner service/process with a standard, non-elevated Windows token. Membership in the local Administrators group is acceptable only when UAC leaves the runner process on its standard-user token; the security preflight rejects an actually elevated Administrator token.

## Antigravity runtime pinning

Treat the Antigravity CLI executable as privileged review infrastructure, not as reviewed code. After every deliberate install or upgrade, resolve and record the exact executable SHA-256:

```powershell
$agyPath = (Get-Command agy -CommandType Application -ErrorAction Stop).Source
(Get-FileHash -LiteralPath $agyPath -Algorithm SHA256).Hash.ToLowerInvariant()
```

Pass that 64-character hash as `AgySha256` when generating the caller workflow. Runner preflight verifies the executable hash before the first `agy` invocation, the review wrapper verifies it again before and after the review process, and the sandbox smoke test does the same. CI invocations set `AGY_CLI_DISABLE_AUTO_UPDATE=true`; upgrades must therefore be deliberate and followed by an explicit re-pin. Prefer an administrator-managed, non-user-writable installation path when deployment policy permits it.

## Review runner

The review runner receives only a public copy of the trusted signing key. It must not have access to the signing account, SSH agent, publisher credential, or GitHub write credentials. Production deployments should prefer an ephemeral self-hosted review runner so one job receives a clean machine state. GitHub explicitly warns that persistent self-hosted runners can be persistently compromised by untrusted workflow code and recommends ephemeral runners for autoscaling.

For an initial persistent Windows pilot, use a dedicated low-privilege Windows account, a dedicated runner label, the sandbox smoke test, workspace cleanup, capability ceilings, and the Windows kill-on-close process job. These controls are defense in depth; they do not turn a persistent runner into an ephemeral isolation boundary.

The review and publisher runner processes must also remain non-elevated. Do not install their runner services as LocalSystem or run them from an elevated terminal.

## Publisher runner

The publisher runner must use a third OS identity and must not check out reviewed PR code. Prefer a dedicated GitHub App installation token. The App should be installed only on intended repositories and have the minimum repository permission needed to create and manage the timeline comment: either Issues write or Pull requests write. Metadata read is implicit for installed Apps. The workflow also verifies the actual account that created the comment.

The fallback reporter token exists for initial deployments only. Do not reuse the signing branch-update credential as the reporter token.

## Repository integration

The privileged caller uses `pull_request_target` deliberately so GitHub loads the caller workflow from the trusted base/default branch instead of from the pull-request merge ref. The caller must reject forks, drafts, non-default target branches, and repository-ID mismatches before invoking the reusable workflow. The reusable workflow independently requires the same event and repeats those checks before allocating a self-hosted runner. Never replace this entrypoint with a PR-controlled `pull_request` workflow that receives Antigravity-CI secrets or self-hosted runner labels.

Use an exact 40-character Antigravity-CI commit SHA in every caller workflow. Do not call a branch or moving tag. The project configuration in `.agy/project.toml` is a privileged policy input; review preparation reads it from the trusted base commit, never from the pull-request head.

Generate an initial caller with `scripts/New-AntigravityCaller.ps1` and provide the pinned `-AgySha256` value from the installed review-runner binary. Generate the initial project config with `scripts/New-ProjectConfig.ps1`. Review the generated files before committing them to a target repository.

The real sandbox acceptance probe is intentionally setup-time/manual. Run `scripts/Test-AgySandboxSmoke.ps1 -ExpectedAgySha256 <pinned-hash>` under the dedicated review account after installing or upgrading AGY and after materially changing Windows sandbox policy.

The reusable workflow rejects forks, draft pull requests, non-default target branches, repository-ID mismatches, and unapproved pull-request actions before allocating the signing runner. The same checks are repeated inside trusted PowerShell code.

## Fresh-turn boundary

A successful AGY report is an output, not permission to continue modifying the pull request. Publication ends the automated turn. A fresh owner/user turn is required before ChatGPT consumes the report, applies fixes, or merges.
