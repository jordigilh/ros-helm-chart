# GitHub Actions Release Workflow Failure Analysis

## Issue Summary

The GitHub Actions release workflow failed at the "Create latest symlink" step for workflow run [#19082060432](https://github.com/insights-onprem/ros-helm-chart/actions/runs/19082060432/job/54513117873).

**Error**: `Process completed with exit code 1` on step "Create latest symlink"

## Root Cause

### Tag Typo
A tag `v01.7` was created instead of `v0.1.7` (missing the dot between 0 and 1).

### Why This Caused the Failure

1. **Workflow trigger**: The tag `v01.7` matched the trigger pattern `v*` in `.github/workflows/release.yml`

2. **Version extraction**: The workflow extracts the version by removing the `v` prefix:
   ```bash
   VERSION=${GITHUB_REF#refs/tags/v}  # Results in "01.7"
   ```

3. **Chart.yaml update**: The workflow updates the chart version to `01.7`:
   ```bash
   sed -i "s/^version:.*/version: 01.7/" ros-ocp/Chart.yaml
   ```

4. **Helm normalization**: When `helm package` runs, it normalizes the version:
   - Input version: `01.7`
   - Normalized version: `1.7` (Helm removes the leading zero)
   - Created file: `ros-ocp-1.7.tgz`

5. **Copy failure**: The workflow tries to copy a file with the non-normalized name:
   ```bash
   cp ros-ocp-01.7.tgz ros-ocp-latest.tgz  # ❌ File not found!
   ```
   But the actual file is named `ros-ocp-1.7.tgz` (without the leading zero).

## Verification

Local testing confirms this behavior:
```bash
# Set Chart.yaml version to 01.7
sed -i 's/^version:.*/version: 01.7/' ros-ocp/Chart.yaml

# Package the chart
helm package ros-ocp
# Output: Successfully packaged chart and saved it to: ros-ocp-1.7.tgz

# Note: Helm created 1.7, not 01.7
```

## Resolution Options

### Option 1: Delete Bad Tag and Create Correct Tag (Recommended for v0.1.7)

If you want to release version 0.1.7:

```bash
# Delete the bad tag locally
git tag -d v01.7

# Delete the bad tag from remote
git push origin :refs/tags/v01.7

# Update Chart.yaml to 0.1.7 (if needed)
sed -i '' 's/^version:.*/version: 0.1.7/' ros-ocp/Chart.yaml
git add ros-ocp/Chart.yaml
git commit -m "chore: bump chart version to 0.1.7"
git push origin main

# Create the correct tag
git tag v0.1.7
git push origin v0.1.7
```

### Option 2: Skip to v0.1.9 (Recommended - Chart Already at 0.1.9)

Since `Chart.yaml` is already at version `0.1.9`, skip the problematic version:

```bash
# Delete the bad tag
git tag -d v01.7
git push origin :refs/tags/v01.7

# Chart.yaml is already at 0.1.9, so just create the tag
git tag v0.1.9
git push origin v0.1.9
```

### Option 3: Fix the Workflow (Preventive)

Add version validation to the workflow to prevent this in the future:

```yaml
- name: Extract version from tag
  id: version
  run: |
    VERSION=${GITHUB_REF#refs/tags/v}
    echo "version=$VERSION" >> $GITHUB_OUTPUT
    echo "tag=${GITHUB_REF#refs/tags/}" >> $GITHUB_OUTPUT

    # Validate semantic versioning format
    if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "Error: Invalid version format '$VERSION'. Must be X.Y.Z"
      exit 1
    fi
```

## Current State

- **Current Chart.yaml version**: `0.1.9`
- **Latest valid tag**: `v0.1.6`
- **Bad tag**: `v01.7` (should be deleted)
- **Recommended next tag**: `v0.1.9`

## Action Required

**Immediate**: Delete the malformed tag `v01.7` from GitHub:

```bash
git push origin :refs/tags/v01.7
```

**Next**: Create the correct release tag:

```bash
# Recommended: Use v0.1.9 since Chart.yaml is already updated
git tag v0.1.9
git push origin v0.1.9
```

This will trigger the release workflow again with the correct version format, and it should succeed.

## Prevention

Consider adding the version validation step (Option 3) to prevent similar issues in the future. This would catch typos in tag names before the workflow attempts to package the chart.

---

**Analysis Date**: November 4, 2025
**Analyzer**: AI Assistant
**Workflow Run**: https://github.com/insights-onprem/ros-helm-chart/actions/runs/19082060432/job/54513117873

