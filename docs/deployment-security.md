# Deployment security

Antigravity-CI separates signing, review, and publication into distinct trust domains. A production deployment should use three different Windows runner identities and deployment-specific labels so a review process cannot inherit signing or publisher authority.

## Signing runner

Every privileged job first replaces system/global Git configuration with a fresh per-job isolation file, an empty hooks directory, an empty global attributes file, and an empty Git template directory. This happens before any checkout. The signing gate selects the SSH signing key explicitly; it does not depend on user-level `gpg.format`, `gpg.ssh.program`, or `user.signingkey` configuration.

The signing target (PR context, merge base, branch ref, and canonical remote) is validated in a credential-free step before the dedicated branch-update token is materialized. The signing runner owns the only private signing key. Keep the private key on the machine and load it through the Windows OpenSSH agent; do not place the private key or its passphrase in GitHub secrets. The workflow receives only the public-key path plus a dedicated branch-update credential. The write credential is scoped to the signing step and is not persisted by checkout.

The signing gate fails fast when the feature history exceeds 250 commits or a commit object exceeds 1 MiB by default. These defaults align with GitHub's PR commit-list display boundary and recommended single-object size, and they prevent a same-repository branch from turning signing into an unbounded privileged-runner workload. Increase them only as an explicit deployment decision.

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

The reusable review workflow runs `Test-AgySandboxSmoke.ps1` on every review-run attempt after host-policy verification and before any pull-request checkout. The smoke AGY process is attached to the same Windows kill-on-close Job Object containment used by the real review so child processes cannot outlive the attestation step. A previous setup-time pass is not sufficient evidence: failure of the current smoke attestation blocks the review. The smoke is bound to the same pinned Antigravity executable SHA-256 used by preflight and the real review invocation. The sandbox smoke accepts an OS-enforced denial of a persistence primitive (for example, a low-privilege account that cannot register Scheduled Tasks) as a valid boundary; do not grant Administrator rights merely to make a control operation succeed. It also probes persistent user-scoped environment state (`HKCU\Environment`) because changes there can affect future processes and tool resolution even after the review workspace is deleted.

The review and publisher runner processes must also remain non-elevated. Do not install their runner services as LocalSystem or run them from an elevated terminal.

The review runner uses the Antigravity account session cached in its dedicated Windows profile. Do not configure Gemini API-key or Google Cloud ADC authentication on that account, and do not set `GEMINI_API_KEY`, `AGY_ADC_AUTH`, `GOOGLE_GEMINI_BASE_URL`, `GOOGLE_APPLICATION_CREDENTIALS`, or `CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE`. Runner preflight rejects those authentication/provider overrides and the AGY child-process sanitizer removes them defensively.

Remote Control is forbidden on the review account. The CLI headless Remote Control feature can register a persistent Windows Scheduled Task and uses the same CLI credentials as normal Antigravity sessions, creating a control path outside the per-review process boundary. Runner preflight therefore rejects persisted Remote Control configuration, Antigravity/agy Scheduled Task markers, and concurrent Antigravity processes. The review wrapper repeats this check before and after AGY so an attempted daemon registration invalidates the run before a report becomes publishable. Do not use `agy --remote-control`, `/remote-control`, or `agy remote-control start` on the dedicated review account.

## Publisher runner

The publisher runner must use a third OS identity and must not check out reviewed PR code. Prefer a dedicated GitHub App installation token. The App should be installed only on intended repositories and have the minimum repository permission needed to create and manage the timeline comment: either Issues write or Pull requests write. Metadata read is implicit for installed Apps. The workflow also verifies the actual account that created the comment.

The fallback reporter token exists for initial deployments only. Do not reuse the signing branch-update credential as the reporter token.

## Default-branch policy protection

The default-branch caller workflow and `.agy/project.toml` are privileged policy files. There are two supported deployment modes:

- **Collaborative mode:** protect the default branch, require pull requests, require at least one approving review, require Code Owner review for the privileged policy files, dismiss stale approvals after new pushes, disallow force pushes/deletions, and apply the rules to administrators where the GitHub plan permits it. Generate exact final CODEOWNERS entries with `scripts/New-PolicyCodeOwners.ps1`; the script requires `.github/CODEOWNERS` and appends root-anchored entries for the CODEOWNERS file itself, the caller workflow, and `.agy/project.toml` last because GitHub gives the last matching CODEOWNERS pattern precedence.
- **Single-writer pilot:** only the repository owner may have write/maintain/admin authority. Treat granting another principal write-capable access as a security-boundary change that requires moving to collaborative mode before privileged review continues.

GitHub currently provides protected branches, rulesets, and CODEOWNERS for private repositories only on GitHub Pro, Team, Enterprise Cloud, or Enterprise Server. A private GitHub Free repository therefore cannot claim collaborative-mode protection; keep it single-writer or change plan/visibility before adding write-capable collaborators.

CODEOWNERS routing alone is not an enforcement boundary. Collaborative mode requires the matching branch protection/ruleset option that makes Code Owner approval mandatory.

## Repository integration

The privileged caller uses `pull_request_target` deliberately so GitHub loads the caller workflow from the trusted base/default branch instead of from the pull-request merge ref. The caller grants only `contents: read` and `pull-requests: read`; reusable workflows cannot elevate `GITHUB_TOKEN` permissions above the caller, so this read ceiling is required for exact live-PR revalidation while still withholding write authority. The caller must reject forks, drafts, non-default target branches, and repository-ID mismatches before invoking the reusable workflow. The reusable workflow independently requires the same event and repeats those checks before allocating a self-hosted runner. Never replace this entrypoint with a PR-controlled `pull_request` workflow that receives Antigravity-CI secrets or self-hosted runner labels.

Use an exact 40-character Antigravity-CI commit SHA in every caller workflow. Do not call a branch or moving tag. The project configuration in `.agy/project.toml` is a privileged policy input; review preparation reads it from the trusted base commit, never from the pull-request head.

Generate an initial caller with `scripts/New-AntigravityCaller.ps1` and provide the pinned `-AgySha256` value from the installed review-runner binary. The generator requires the caller to live under `.github/workflows/`, requires three distinct runner labels, and validates the expected reporter login before rendering secrets or runner inputs. Generate the initial project config with `scripts/New-ProjectConfig.ps1`; it writes only the canonical `.agy/project.toml` policy location. Review the generated files before committing them to a target repository.

The real sandbox acceptance probe is part of every privileged review run. You may also run `scripts/Test-AgySandboxSmoke.ps1 -ExpectedAgySha256 <pinned-hash>` manually under the dedicated review account after installing or upgrading AGY or changing Windows sandbox policy, but a manual pass never substitutes for the per-review gate. The smoke creates outside-workspace file sentinels and a session-only Generic Credential sentinel, then asks the exact pinned AGY process to run a fixed sandboxed probe. It checks protected reads/writes, Credential Manager read and write persistence, Task Scheduler registration, `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` persistence, persistent `HKCU\Environment` user variables, and outbound HTTPS. Where the low-privilege host account already denies a persistence primitive, that host policy is accepted as the stronger boundary; the account is never elevated merely to make a control operation succeed. This applies to Scheduled Task registration, HKCU Run-key writes, and persistent user-environment writes; in all cases the post-probe host check still requires that no sandbox-created state exists. Acceptance always requires that the sandboxed probe cannot create or leave persistent state, cannot reach the protected credential/file sentinels, cannot use unapproved outbound network access, and does not leak sentinel values into AGY output. The live smoke also launches a harmless sibling process under the review account and requires the sandbox to be unable to obtain memory-read or terminate handles to it. The smoke consumes Antigravity `stream-json` output and requires an observed `DONE` `run_command` tool event whose `CommandLine` is exactly `pwsh -NoProfile -File .\sandbox-probe.ps1`; any other tool invocation or command fails the attestation. It also rejects `always-proceed` permission mode and an unexpected CLI working directory, so the result file and final model response are not the sole evidence that the probe actually executed.

For repositories that support collaborative mode, run `scripts/New-PolicyCodeOwners.ps1 -OutputPath .github/CODEOWNERS -CodeOwner @owner-or-org/team` after generating the caller. The generator rejects whitespace and CODEOWNERS pattern metacharacters in a custom caller path, migrates legacy unanchored exact entries to root-anchored rules, and protects `.github/CODEOWNERS` itself. If an existing exact policy entry names a different owner, the generator fails unless `-Force` is supplied; review that replacement deliberately.

The reusable workflow rejects forks, draft pull requests, non-default target branches, repository-ID mismatches, and unapproved pull-request actions before allocating the signing runner. The same checks are repeated inside trusted PowerShell code.

## Fresh-turn boundary

A successful AGY report is an output, not permission to continue modifying the pull request. Publication ends the automated turn. A fresh owner/user turn is required before ChatGPT consumes the report, applies fixes, or merges.
