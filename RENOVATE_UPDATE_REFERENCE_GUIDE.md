# Renovate Update Reference Guide

This document categorizes all `uses:` references in the test fixture workflows and explains how the Renovate configuration handles each category, including which rules apply and why updates are made.

## Overview

The test fixture files contain three types of dependency references:
- **Standard GitHub Actions** (e.g., `actions/checkout`, `actions/cache`)
- **Standard Reusable Workflows** (e.g., `actions/reusable-workflows`)
- **Path-Prefixed Self-References** (e.g., `owner/repo/.github/actions/my-action@tag` or `.github/workflows/my-workflow@tag`)

Each category uses different Renovate managers and rules to compute updates.

---

## Reference Categories

### Category 1: Standard Actions/Workflows via Semver Tag

**Example:**
```yaml
uses: actions/checkout@v6.0.0
uses: actions/setup-node@v3
```

**Renovate Manager:** `github-actions`

**Configuration Applied:**
- Rule: `"Allow minor and patch updates for non-ETAS GitHub Actions dependencies"` or `"Allow minor and patch updates for ETAS GitHub Actions dependencies"`
- `matchUpdateTypes: ["minor", "patch"]`

**Update Behavior:**
1. Renovate parses `v6.0.0` as semver.
2. Looks up latest `v6.x.x` tag in the repository.
3. Updates to the newest tag that is semver-compatible (major version 6 only).
4. Example: `v6.0.0` → `v6.0.3` or higher patch/minor within v6.

**PR Details:**
- Branch: `renovate/baseBranch-actions-checkout-6_x`
- PR Title: `Update actions/checkout action to v6.0.3`
- Commit Message: `Update actions/checkout action to v6.0.3`

---

### Category 2: Standard Actions/Workflows via Branch Reference (Pinned to Digest)

**Example:**
```yaml
uses: actions/checkout@main
uses: mtombosch/cicd-workflows/.github/workflows/bzlmod-lock-check.yml@main
```

**Renovate Manager:** `github-actions` (via `pinDigest` or `digest`)

**Configuration Applied:**
- `github-actions` digest detection matches branch-like `currentValue` (not commit SHA, not semver)
- Rules: 
  - `"Allow github-actions digest updates for non-whitespace refs"` (enabled)
  - `"Create per-dependency branch commit pinning PRs"` (for `pinDigest` updates)
  - `"Create per-dependency branch based digest update PRs"` (for `digest` updates)
- `matchUpdateTypes: ["pinDigest", "digest"]`
- `groupName: null` (ensures one PR per dependency)

**Update Behavior:**
1. Renovate fetches the HEAD commit of the branch `main`.
2. Pins the reference to that commit SHA (digest).
3. Adds an inline comment preserving the branch name: `@sha # main`
4. If the branch HEAD moves, a new digest update PR is created with a new commit SHA.

**PR Details (pinDigest):**
- Branch: `renovate/baseBranch-actions-checkout__pin-main-to__4f1f4aec...`
- PR Title: `Pin actions/checkout main to 4f1f4aec02e41874fa0262ea8ff5172d7978ad1e`
- Commit Message: `Pin actions/checkout main to 4f1f4aec02e41874fa0262ea8ff5172d7978ad1e`

**PR Details (digest):**
- Branch: `renovate/baseBranch-eclipse-score-cicd-workflows__main-branch-digest-update-to__17318d27...`
- PR Title: `Update eclipse-score/cicd-workflows digest of branch main to 173...`
- Commit Message: `Update eclipse-score/cicd-workflows digest of branch main to 173...`

> **Note – path-prefixed refs with a direct branch reference** (e.g., `owner/repo/.github/actions/my-action@main`, cases 16 and 22 in the use-case list): The `custom.regex` `matchStrings` pattern requires `currentValue` to contain `/`; a plain branch name such as `main` does not satisfy that, so `custom.regex` skips the ref. The `github-actions` manager then processes it with the same `pinDigest`/`digest` branch-tracking logic described in this category. The rule `"Disable native github-actions handling of path-prefixed tags"` does not suppress these because its `matchCurrentValue` filter (`/^[^/\s]+\/\S+$/`) only matches values that already contain `/`.

---

### Category 3: Standard Actions/Workflows via Commit SHA with Version Comment

**Example:**
```yaml
uses: actions/cache@1bd1e32a3bdc45362d1e726936510720a7c30a57 # v4.2.0
uses: actions/checkout@8ade135a41bc03ea155e62e844d188df1ea18608 # v4.3.1
uses: actions/reusable-workflows/.github/workflows/basic-validation.yml@95d9656793415e47f574f7967f3850ea3bf5a7ed # v1.0.0
```

**Renovate Manager:** `github-actions`

**Configuration Applied:**
- Rules:
  - `"Allow github-actions digest updates for non-whitespace refs"` (enabled)
  - `"Disable github-actions digest updates when currentValue is semver-like"` (disabled for this category because it matches version comment pattern)
  - `"Allow github-actions pinDigest updates for non-whitespace refs"` (enabled)
- `matchCurrentValue: /^v?\d+(?:\.\d+){0,2}$/` matches the version comment

**Update Behavior:**
1. Renovate parses the version comment (e.g., `v4.2.0`, `4.2.0`, `v4`) as the semantic version.
2. Ignores the commit SHA; uses the version comment for lookup.
3. Finds the latest semver-compatible tag and resolves it to its commit SHA.
4. Updates the reference SHA to point to the newest compatible version commit.
5. Updates the version comment inline: `@newDigest # newVersion`

**PR Details:**
- Branch: `renovate/baseBranch-actions-cache-4_x`
- PR Title: `Update actions/cache action to v4.3.0`
- Commit Message: `Update actions/cache action to v4.3.0`

---

### Category 4: Standard Actions/Workflows via Commit SHA Without Version Comment

**Example:**
```yaml
uses: actions/checkout@8ade135a41bc03ea155e62e844d188df1ea18608
uses: mtombosch/cicd-actions/inter-repo-access@51883d9cd772bee5b7d139a2e6ffd8aeabca4224
```

**Renovate Manager:** `github-actions`

**Configuration Applied:**
- Rules:
  - `"Allow github-actions digest updates for non-whitespace refs"` (enabled)
  - `"Disable github-actions digest updates when currentValue is a commit SHA"` (disabled because commit SHA has no version comment)
- `matchCurrentValue: /^[0-9a-f]{40}$/` matches commit SHA

**Update Behavior:**
1. Renovate attempts to resolve the commit SHA to a known tag.
2. If successful, uses the tag to find semver-compatible updates.
3. If no tags exist and no version comment is available, **no update is performed**.
4. Reason: Renovate cannot determine the intended semantic version without a version comment.

**PR Details:**
- No PR generated (no update)
- Reported in `RENOVATE_UNCHANGED_REFERENCES.log` with `skipReason: "invalid-version"`

---

### Category 5: Path-Prefixed Self-References via Tag-as-Ref

**Example:**
```yaml
uses: mtombosch/dependabot_update_scenarios_test/.github/actions/dummy-composite@dummy-composite/v1.0.0
uses: mtombosch/dependabot_update_scenarios_test/.github/workflows/dummy_reusable_workflow.yml@dummy-workflow/v1.1.0
```

**Renovate Manager:** `custom.regex` (first custom manager in config)

**Configuration Applied:**
- Manager: `"Unified handler for both forms"` (path-prefixed refs)
- `depNameTemplate: "{{{depName}}}/{{{actionPath}}}"` creates path-aware identity
- `versioningTemplate: "regex:^(?<compatibility>[^/]+)/v?(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)$"` parses path-prefixed tags
- Rules:
  - `"For custom.regex path-prefixed tags, enable digest pinning"` (pinDigests: true)
  - `"Allow minor and patch updates for non-ETAS GitHub Actions dependencies"`

**Update Behavior:**
1. Renovate extracts the path (`dummy-composite` or `dummy_reusable_workflow`) and tag (`dummy-composite/v1.0.0`).
2. Uses the path-prefixed tag format to identify the dependency uniquely (avoids grouping unrelated refs like `dummy-composite` vs `dummy_reusable_workflow`).
3. Looks up latest semver-compatible tag with the same prefix (e.g., `dummy-composite/v1.2.0`).
4. Resolves the tag to its commit SHA and pins the reference: `@sha # dummy-composite/v1.2.0`

**PR Details:**
- Branch: `renovate/baseBranch-mtombosch-dependabot_update_scenarios_test-_github-actions-dummy-composite-1_x`
- PR Title: `Update dependency mtombosch/dependabot_update_scenarios_test/.github/actions/dummy-composite to dummy-composite/v1.2.0`
- Commit Message: `Update dependency mtombosch/dependabot_update_scenarios_test/.github/actions/dummy-composite to dummy-composite/v1.2.0`

**Why This Manager is Required:**
- Native `github-actions` manager cannot parse path-prefixed tags like `dummy-composite/v1.0.0` because the default semver versioning cannot handle the path prefix.
- The custom regex manager with explicit `versioningTemplate` handles the path prefix parsing and produces consistent updates for all path-prefixed variants.

---

### Category 6: Path-Prefixed Self-References via Pinned Digest with Multi-Path Version Comment

**Example:**
```yaml
uses: mtombosch/dependabot_update_scenarios_test/.github/actions/dummy-composite@150be11f8e18450c38116b01268b2b7119b87931 # dummy-composite/v1.0.0
uses: mtombosch/dependabot_update_scenarios_test/.github/workflows/dummy_reusable_workflow.yml@150be11f8e18450c38116b01268b2b7119b87931 # dummy-workflow/v1.1.0
```

**Renovate Manager:** `custom.regex` (first custom manager in config)

**Configuration Applied:**
- Manager: `"Unified handler for both forms"` (path-prefixed refs)
- `matchStrings` captures:
  - `depName`: `mtombosch/dependabot_update_scenarios_test`
  - `actionPath`: `.github/actions/dummy-composite`
  - `currentDigest`: `150be11f8e18450c38116b01268b2b7119b87931`
  - `currentValue`: `dummy-composite/v1.0.0` (from the comment)
- Rules:
  - `"For custom.regex path-prefixed tags, enable digest pinning"` (pinDigests: true)
  - `"Disable custom.regex pinDigest-only updates for path-prefixed refs"` (avoids duplicate pin-only branches)
  - `"Allow minor and patch updates"`

**Update Behavior:**
1. Renovate parses the path (`dummy-composite`) and version comment (`dummy-composite/v1.0.0`).
2. The inline comment serves as the semantic version hint (similar to Category 3).
3. Finds the latest semver-compatible tag with the same prefix (e.g., `dummy-composite/v1.2.0`).
4. Resolves the new tag to its commit SHA and updates both the digest and the comment: `@newDigest # dummy-composite/v1.2.0`

**PR Details:**
- Branch: `renovate/baseBranch-mtombosch-dependabot_update_scenarios_test-_github-actions-dummy-composite-1_x`
- PR Title: `Update dependency mtombosch/dependabot_update_scenarios_test/.github/actions/dummy-composite to dummy-composite/v1.2.0`
- Commit Message: `Update dependency mtombosch/dependabot_update_scenarios_test/.github/actions/dummy-composite to dummy-composite/v1.2.0`

**Why This Pattern is Required:**
- Path-prefixed tags (e.g., `dummy-composite/v1.0.0`) allow a single repository to host multiple versioned components.
- The multi-path version comment disambiguates which component's version the reference tracks.
- Without this, Renovate cannot distinguish between `dummy-composite/v1.0.0` and `dummy_reusable_workflow/v1.0.0` tags in the same repository.

---

### Category 7: Actions/Workflows via Commit SHA with Branch Name Comment

Covers use cases where the ref is a 40-character commit SHA and the inline comment holds a plain branch name (not a SemVer version). Applies to:
- Standard GitHub Action with branch comment (use case 1)
- Standard reusable workflow with branch comment (use case 7)
- Path-prefixed action with branch comment (use case 13)
- Path-prefixed reusable workflow with branch comment (use case 19)

For path-prefixed refs the `custom.regex` `matchStrings` pattern requires `currentValue` to match `[^/\s]+/\S+` (must contain `/`). A bare branch name like `main` has no `/`, so `custom.regex` does not capture it and the `github-actions` manager processes it instead.

**Example:**
```yaml
# Standard action:
uses: actions/checkout@8ade135a41bc03ea155e62e844d188df1ea18608 # main
# Standard reusable workflow:
uses: actions/reusable-workflows/.github/workflows/basic-validation.yml@95d9656793415e47f574f7967f3850ea3bf5a7ed # main
# Path-prefixed action (custom.regex not applicable; github-actions handles it):
uses: mtombosch/dependabot_update_scenarios_test/.github/actions/dummy-composite@150be11f8e18450c38116b01268b2b7119b87931 # main
# Path-prefixed reusable workflow (same fallthrough):
uses: mtombosch/dependabot_update_scenarios_test/.github/workflows/dummy_reusable_workflow.yml@150be11f8e18450c38116b01268b2b7119b87931 # main
```

**Renovate Manager:** `github-actions`

**Configuration Applied:**
- Rules:
  - `"Allow github-actions digest updates for non-whitespace refs"` (enabled; `main` is non-whitespace)
  - `"Disable github-actions digest updates when currentValue is a commit SHA"` (not triggered; `main` is not a 40-char hex SHA)
  - `"Disable github-actions digest updates when currentValue is semver-like"` (not triggered; `main` is not semver)
  - `"Create per-dependency branch based digest update PRs"` (one PR per dependency; `groupName: null`)

**Relationship to Category 2:**
- Category 2 (`@branch`, no SHA) is the unpinned form; it receives a `pinDigest` update that pins the ref to the current branch HEAD, producing the `@sha # branch` form.
- Category 7 (`@sha # branch`) is already in pinned form; it only receives `digest` refresh updates when the branch HEAD advances.
- Both forms converge to the same stable state: `@<sha> # <branch>`.

**Update Behavior:**
1. Renovate extracts `currentDigest` from the 40-char SHA and `currentValue` from the branch name in the comment.
2. The branch name cannot be parsed as SemVer; Renovate resolves the branch to its current HEAD commit.
3. If the branch HEAD differs from `currentDigest`, a `digest` PR is created with the updated SHA.
4. Result: `@<oldsha> # main` → `@<newsha> # main`

**PR Details:**
- Branch: `renovate/baseBranch-{depNameSanitized}__{currentValue}-branch-digest-update-to__{newDigest}`
- PR Title: `Update {depName} digest of branch main to {newDigest}`
- Commit Message: `Update {depName} digest of branch main to {newDigest}`

---

### Category 8: Path-Prefixed Self-References via Major-Only Version Tag or Comment (No Update)

Covers path-prefixed action and reusable workflow references where the version uses only a major number with its path prefix (e.g., `dummy-composite/v1`), with no minor or patch component. Applies to:
- Path-prefixed action: direct major-only tag (use case 18)
- Path-prefixed action: SHA with major-only path-prefixed comment (use case 15)
- Path-prefixed reusable workflow: direct major-only tag (use case 24)
- Path-prefixed reusable workflow: SHA with major-only path-prefixed comment (use case 21)

**Example:**
```yaml
# Path-prefixed action, direct major-only tag:
uses: mtombosch/dependabot_update_scenarios_test/.github/actions/dummy-composite@dummy-composite/v1
# Path-prefixed action, SHA with major-only path-prefixed comment:
uses: mtombosch/dependabot_update_scenarios_test/.github/actions/dummy-composite@150be11f8e18450c38116b01268b2b7119b87931 # dummy-composite/v1
# Path-prefixed reusable workflow, direct major-only tag:
uses: mtombosch/dependabot_update_scenarios_test/.github/workflows/dummy_reusable_workflow.yml@dummy-workflow/v1
# Path-prefixed reusable workflow, SHA with major-only path-prefixed comment:
uses: mtombosch/dependabot_update_scenarios_test/.github/workflows/dummy_reusable_workflow.yml@150be11f8e18450c38116b01268b2b7119b87931 # dummy-workflow/v1
```

**Renovate Manager:** `custom.regex` (`currentValue` contains `/`, e.g. `dummy-composite/v1`, so the `matchStrings` pattern captures it)

**Configuration Applied:**
- `custom.regex` `matchStrings` captures the ref; `currentValue` is set to the major-only prefixed tag (e.g., `dummy-composite/v1`).
- `versioningTemplate: "regex:^(?<compatibility>[^/]+)/v?(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)$"` is applied.
- `dummy-composite/v1` does not satisfy this pattern: it provides only `major` but the template requires all three of `major.minor.patch`.

**Update Behavior:**
1. `custom.regex` extracts the ref but version parsing fails because the `versioningTemplate` requires full three-part SemVer.
2. Renovate cannot determine a valid starting version; no compatible update is computed.
3. No PR is generated; the reference is left unchanged.

**PR Details:**
- No PR generated.

**Note:** To support major-only path-prefixed version tags the `versioningTemplate` in `customManagers` would need to be extended to accept an optional minor/patch group, e.g.:
`"regex:^(?<compatibility>[^/]+)/v?(?<major>\\d+)(?:\\.(?<minor>\\d+)\\.(?<patch>\\d+))?$"`

---

## Configuration Summary

### Renovate Managers

| Manager | Purpose | Use Cases |
|---------|---------|-----------|
| `github-actions` | Handles standard GitHub Actions and reusable workflows | Semver tags, branch refs, commits with version comments |
| `custom.regex` (1st) | Handles path-prefixed in-repo actions and workflows | `owner/repo/.github/actions/name@tag`, `owner/repo/.github/workflows/name@tag` |

### Key Package Rules

| Rule | Update Types | Behavior |
|------|------------|----------|
| Minor/Patch Updates | `minor`, `patch` | Allowed; updates to latest semver-compatible version |
| Major Updates | `major` | Disabled globally; can be enabled per-dependency |
| Branch Digest Pinning | `pinDigest`, `digest` | One PR per dependency; pins branch HEAD to commit SHA |
| SHA + Branch Comment | `digest` | Digest-only refresh (already pinned); branch name preserved in comment |
| Path-Prefixed Pinning | `pinDigest` | One PR per path-prefixed dependency; avoids grouping |
| Path-Prefixed Major-Only | none | No update; `versioningTemplate` requires `major.minor.patch` |
| Disabled Refs | commit SHA without comment | No update (skip); cannot determine semantic version |

### Commit Message Format

All digest updates follow the template:
- **Action:** `Pin` (for pinDigest) or `Update` (for digest)
- **Topic:** `{depName} {currentValue}` (includes branch name or path)
- **Extra:** `to {newDigest}` (shows the new commit SHA)

**Result:** "Pin actions/checkout main to 4f1f4aec..."

---

## Flow Diagram: How Renovate Decides on an Update

```
┌─ Detect reference (uses: ...)
│
├─ Match manager?
│  ├─ github-actions: Standard actions/workflows
│  └─ custom.regex: Path-prefixed self-references
│
├─ Extract version hint
│  ├─ Semver tag? (v1.2.3)
│  ├─ Branch? (main)
│  ├─ Commit + version comment? (sha # v1.2.3)
│  ├─ Commit + multi-path comment? (sha # prefix/v1.2.3)
│  └─ Commit only? (sha)
│
├─ Apply matching package rules
│  ├─ Version type (minor/patch/major/digest/pinDigest)?
│  ├─ Current value matches pattern?
│  └─ Is this update enabled?
│
├─ If enabled: compute new version
│  ├─ Query repository tags
│  ├─ Filter by semver compatibility
│  └─ Return latest compatible version
│
└─ Generate PR
   ├─ Set branchTopic + commitMessage
   ├─ Create PR folder (sanitize / and . to _)
   └─ Write snapshot and patch files
```

---

## Notes on Limitations

1. **No automatic digest pinning of branch refs without custom rules:** Standard Renovate does not automatically pin `@main` to a commit SHA. This config explicitly enables `pinDigest` for branch refs to provide better auditability.

2. **Major version updates are disabled globally:** This requires per-repository opt-in for major updates to give the infrastructure team centralized control.

3. **Path-prefixed tags require custom manager:** The default `github-actions` manager cannot parse `prefix/vX.Y.Z` style tags; the custom regex manager with explicit versioning template is mandatory.

4. **One PR per dependency via `groupName: null`:** Prevents unrelated updates from being grouped into a single PR, making reviews and reversions independent.

---

## Relevant Configuration File Sections

See [.github/renovate.json5](./.github/renovate.json5) for:
- `customManagers` (lines ~38–78): Defines the custom regex manager for path-prefixed refs
- `packageRules` (lines ~80–400+): Defines update rules by manager, update type, and version pattern
