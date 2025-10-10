# ROS-OCP CI/CD Guide

GitHub workflows, automation, and continuous integration/deployment for the ROS-OCP Helm chart.

## Table of Contents
- [GitHub Workflows Overview](#github-workflows-overview)
- [Workflow Details](#workflow-details)
- [CI/CD Integration](#cicd-integration)
- [Release Process](#release-process)
- [Local Testing](#local-testing)

## GitHub Workflows Overview

The repository includes automated workflows for continuous integration, testing, and deployment:

| Workflow | Purpose | Runtime | Triggers |
|----------|---------|---------|----------|
| **[Lint & Validate](#lint-and-validate)** | Chart validation | ~10 min | PR, Push to main |
| **[Version Check](#version-check)** | Semantic versioning | ~5 min | PR, Push to main |
| **[Test Deployment](#test-deployment)** | E2E testing | ~45 min | PR, Push to main |
| **[Create Release](#create-release)** | Automated releases | ~10 min | Version tags |

**Total validation time:** ~60 minutes for full test suite

---

## Workflow Details

### Lint and Validate

**File:** `.github/workflows/lint-and-validate.yml`

**Purpose:** Fast validation of Helm chart correctness without full deployment.

**Triggers:**
- Pull requests to `main` or `master`
- Pushes to `main` or `master`
- Only when `ros-ocp/**` files change
- Manual dispatch via GitHub Actions UI

**Actions Performed:**
1. **Helm Lint**
   ```bash
   helm lint ./ros-ocp
   ```
   - Validates Chart.yaml structure
   - Checks template syntax
   - Verifies dependencies

2. **Template Validation**
   ```bash
   helm template test-release ./ros-ocp --validate
   ```
   - Renders all templates
   - Validates against Kubernetes schemas
   - Checks for template errors

3. **Dependency Validation**
   - Checks if dependencies are defined
   - Validates dependency versions
   - Updates dependencies if needed

**Example Output:**
```
==> Linting ros-ocp
[INFO] Chart.yaml: icon is recommended
1 chart(s) linted, 0 chart(s) failed

==> Validating templates
✓ All templates valid
```

**When It Fails:**
- Invalid YAML syntax
- Missing required fields
- Template rendering errors
- Invalid Kubernetes resource definitions

---

### Version Check

**File:** `.github/workflows/version-check.yml`

**Purpose:** Validate chart version follows semantic versioning and is higher than previous releases.

**Triggers:**
- Pull requests to `main` or `master`
- Pushes to `main` or `master`
- Only when `ros-ocp/Chart.yaml` changes
- Manual dispatch

**Actions Performed:**
1. **Extract Current Version**
   ```bash
   CURRENT_VERSION=$(grep '^version:' ros-ocp/Chart.yaml | awk '{print $2}')
   ```

2. **Get Latest Release Version**
   ```bash
   LATEST_VERSION=$(curl -s https://api.github.com/repos/.../releases/latest | jq -r '.tag_name')
   ```

3. **Semantic Version Comparison**
   - Validates current version is valid semver (e.g., `1.2.3`)
   - Compares with latest release version
   - Ensures current > latest

4. **PR Comments**
   - Adds comment with version comparison
   - Suggests appropriate version bump (patch/minor/major)
   - Links to semver documentation

**Example Comment:**
```markdown
## Version Check Results

📊 **Current version:** `0.2.1`
📦 **Latest release:** `0.2.0`
✅ **Status:** Version is valid and higher than latest release

### Version Comparison
- Current: 0.2.1
- Latest:  0.2.0
- Bump:    PATCH
```

**When It Fails:**
- Version is not valid semver
- Version is not higher than latest release
- Version is exactly the same as existing release

---

### Test Deployment

**File:** `.github/workflows/test-deployment.yml`

**Purpose:** Complete end-to-end deployment testing in ephemeral KIND cluster.

**Triggers:**
- Pull requests to `main` or `master`
- Pushes to `main` or `master`
- When `ros-ocp/**` or `scripts/**` change
- Manual dispatch

**Workflow Steps:**

#### 1. Environment Setup
```yaml
- name: Checkout code
  uses: actions/checkout@v4

- name: Set up kubectl
  uses: azure/setup-kubectl@v3

- name: Set up Helm
  uses: azure/setup-helm@v3
```

#### 2. Create KIND Cluster
```yaml
- name: Create KIND cluster
  run: |
    ./scripts/deploy-kind.sh
```
- Creates KIND cluster with ingress controller
- Configures port mapping (32061)
- Sets up container runtime

#### 3. Deploy ROS-OCP
```yaml
- name: Deploy ROS-OCP
  run: |
    export USE_LOCAL_CHART=true
    ./scripts/install-helm-chart.sh
```
- Uses local chart from PR/branch
- Deploys all services
- Waits for pods to be ready

#### 4. Health Checks
```yaml
- name: Run health checks
  run: |
    ./scripts/install-helm-chart.sh health
```
- Verifies all pods are running
- Tests internal connectivity
- Tests external endpoints

#### 5. Connectivity Tests
```bash
# Test ingress health
curl -f http://localhost:32061/ready

# Test ROS API
curl -f http://localhost:32061/status

# Test Kruize API
curl -f http://localhost:32061/api/kruize/health
```

#### 6. Cleanup
```yaml
- name: Cleanup
  if: always()
  run: |
    ./scripts/cleanup-kind-artifacts.sh
```
- Always runs (success or failure)
- Removes KIND cluster
- Cleans up containers and networks

**Runtime Breakdown:**
- KIND cluster creation: ~5 minutes
- Deployment: ~25 minutes
- Health checks: ~10 minutes
- Cleanup: ~5 minutes
- **Total:** ~45 minutes

**When It Fails:**
- Pod fails to start
- Health checks timeout
- Connectivity tests fail
- Insufficient resources
- Chart template errors

---

### Create Release

**File:** `.github/workflows/release.yml`

**Purpose:** Automated release creation when version tags are pushed.

**Triggers:**
- Push of version tags matching `v*` (e.g., `v0.2.0`, `v1.0.0`)

**Workflow Steps:**

#### 1. Extract Version
```yaml
- name: Get version from tag
  run: |
    VERSION=${GITHUB_REF#refs/tags/v}
    echo "VERSION=$VERSION" >> $GITHUB_ENV
```

#### 2. Update Chart Version
```yaml
- name: Update Chart.yaml version
  run: |
    sed -i "s/^version:.*/version: $VERSION/" ros-ocp/Chart.yaml
```

#### 3. Package Chart
```yaml
- name: Package Helm chart
  run: |
    helm package ros-ocp --destination dist/
```
- Creates versioned .tgz file: `ros-ocp-0.2.0.tgz`
- Also creates `ros-ocp-latest.tgz` for convenience

#### 4. Generate Release Notes
```yaml
- name: Generate release notes
  run: |
    cat > release-notes.md << EOF
    ## ROS-OCP Helm Chart v$VERSION

    ### Installation
    \`\`\`bash
    curl -LO https://github.com/.../releases/download/v$VERSION/ros-ocp-$VERSION.tgz
    helm install ros-ocp ros-ocp-$VERSION.tgz -n ros-ocp --create-namespace
    \`\`\`
    EOF
```

#### 5. Create GitHub Release
```yaml
- name: Create Release
  uses: softprops/action-gh-release@v1
  with:
    files: |
      dist/ros-ocp-$VERSION.tgz
      dist/ros-ocp-latest.tgz
    body_path: release-notes.md
    draft: false
    prerelease: false
```

**Release Artifacts:**
- `ros-ocp-{version}.tgz` - Versioned chart package
- `ros-ocp-latest.tgz` - Always points to latest version

**Release Notes Include:**
- Installation instructions
- What's changed (auto-generated from commits)
- Download links

---

## CI/CD Integration

### GitHub Actions Integration

**Example workflow using ROS-OCP chart:**

```yaml
name: Deploy Application

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup KIND
        run: |
          curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
          chmod +x ./kind
          sudo mv ./kind /usr/local/bin/kind

      - name: Create test cluster
        run: |
          git clone https://github.com/insights-onprem/ros-helm-chart.git
          cd ros-helm-chart
          ./scripts/deploy-kind.sh

      - name: Deploy ROS-OCP
        run: |
          cd ros-helm-chart
          ./scripts/install-helm-chart.sh

      - name: Run tests
        run: |
          # Your application tests here
          curl -f http://localhost:32061/ready

      - name: Cleanup
        if: always()
        run: |
          cd ros-helm-chart
          ./scripts/cleanup-kind-artifacts.sh
```

### GitLab CI Integration

```yaml
# .gitlab-ci.yml
stages:
  - test
  - deploy

test:
  stage: test
  image: ubuntu:22.04
  services:
    - docker:dind
  script:
    - apt-get update && apt-get install -y curl jq
    - curl -LO https://dl.k8s.io/release/v1.28.0/bin/linux/amd64/kubectl
    - chmod +x kubectl && mv kubectl /usr/local/bin/
    - curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    - git clone https://github.com/insights-onprem/ros-helm-chart.git
    - cd ros-helm-chart
    - ./scripts/deploy-kind.sh
    - export USE_LOCAL_CHART=true
    - ./scripts/install-helm-chart.sh
    - ./scripts/install-helm-chart.sh health
  after_script:
    - cd ros-helm-chart && ./scripts/cleanup-kind-artifacts.sh
```

### Jenkins Integration

```groovy
// Jenkinsfile
pipeline {
    agent any

    stages {
        stage('Setup') {
            steps {
                git 'https://github.com/insights-onprem/ros-helm-chart.git'
            }
        }

        stage('Deploy KIND') {
            steps {
                sh './scripts/deploy-kind.sh'
            }
        }

        stage('Deploy ROS-OCP') {
            steps {
                sh 'USE_LOCAL_CHART=true ./scripts/install-helm-chart.sh'
            }
        }

        stage('Test') {
            steps {
                sh './scripts/install-helm-chart.sh health'
                sh 'curl -f http://localhost:32061/ready'
            }
        }
    }

    post {
        always {
            sh './scripts/cleanup-kind-artifacts.sh'
        }
    }
}
```

---

## Release Process

### Creating a New Release

#### 1. Update Version

```bash
# Edit Chart.yaml
vim ros-ocp/Chart.yaml

# Update version following semver
version: 0.3.0  # was 0.2.1
```

**Version Guidelines:**
- **Patch** (0.2.1 → 0.2.2): Bug fixes, no breaking changes
- **Minor** (0.2.1 → 0.3.0): New features, backward compatible
- **Major** (0.2.1 → 1.0.0): Breaking changes

#### 2. Commit Changes

```bash
git add ros-ocp/Chart.yaml
git commit -m "chore: bump version to 0.3.0"
git push origin main
```

#### 3. Create and Push Tag

```bash
# Create annotated tag
git tag -a v0.3.0 -m "Release v0.3.0

- Added feature X
- Fixed issue Y
- Updated dependency Z
"

# Push tag to trigger release workflow
git push origin v0.3.0
```

#### 4. Monitor Release Workflow

```bash
# Watch workflow progress
gh run watch

# Or view in GitHub Actions UI
# https://github.com/insights-onprem/ros-helm-chart/actions
```

#### 5. Verify Release

```bash
# Check release was created
gh release view v0.3.0

# Download and test
curl -LO https://github.com/insights-onprem/ros-helm-chart/releases/download/v0.3.0/ros-ocp-0.3.0.tgz
helm install ros-ocp ros-ocp-0.3.0.tgz -n test --create-namespace --dry-run
```

### Pre-release Process

For testing before official release:

```bash
# Create pre-release tag
git tag -a v0.3.0-rc1 -m "Release candidate 1 for v0.3.0"
git push origin v0.3.0-rc1

# Workflow creates release marked as pre-release
# Test thoroughly before creating final release
```

---

## Local Testing

### Test Workflow Steps Locally

#### 1. Lint and Validate

```bash
# Run lint
helm lint ./ros-ocp

# Validate templates
helm template test-release ./ros-ocp --validate

# Check for issues
helm template test-release ./ros-ocp --debug
```

#### 2. Version Check

```bash
# Get current version
CURRENT=$(grep '^version:' ros-ocp/Chart.yaml | awk '{print $2}')

# Get latest release
LATEST=$(curl -s https://api.github.com/repos/insights-onprem/ros-helm-chart/releases/latest | jq -r '.tag_name' | sed 's/v//')

# Compare
echo "Current: $CURRENT"
echo "Latest: $LATEST"

# Validate semver
echo $CURRENT | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' && echo "Valid" || echo "Invalid"
```

#### 3. Full Deployment Test

```bash
# Complete E2E test
./scripts/deploy-kind.sh
export USE_LOCAL_CHART=true
./scripts/install-helm-chart.sh
./scripts/install-helm-chart.sh health

# Cleanup
./scripts/cleanup-kind-artifacts.sh
```

#### 4. Package and Test

```bash
# Package chart
helm package ./ros-ocp

# Install from package
helm install test-release ./ros-ocp-*.tgz \
  -n test-ros \
  --create-namespace \
  --dry-run

# Cleanup
rm -f ros-ocp-*.tgz
```

---

## Workflow Best Practices

### For Contributors

✅ **Do:**
- Run `helm lint` before creating PR
- Test locally with KIND before pushing
- Update version in Chart.yaml for new features
- Add descriptive commit messages
- Wait for all CI checks to pass

❌ **Don't:**
- Push directly to main (use PRs)
- Skip local testing
- Ignore CI failures
- Create releases without version bump

### For Maintainers

✅ **Do:**
- Review all CI check results before merging
- Test pre-releases before final release
- Document breaking changes in release notes
- Monitor workflow run times
- Clean up old releases/artifacts

❌ **Don't:**
- Merge PRs with failing tests
- Skip version validation
- Release without testing
- Ignore workflow failures

---

## Troubleshooting Workflows

### Workflow Fails - Lint

```bash
# Common issues:
# 1. YAML syntax errors
yamllint ros-ocp/templates/*.yaml

# 2. Template syntax errors
helm template test ./ros-ocp --debug

# 3. Missing required fields
helm lint ./ros-ocp --strict
```

### Workflow Fails - Test Deployment

```bash
# Check KIND cluster
kind get clusters

# Check docker/podman
docker ps -a

# View KIND logs
kind export logs --name ros-ocp-cluster

# Test locally
./scripts/deploy-kind.sh
kubectl get pods -A
```

### Workflow Fails - Release

```bash
# Common issues:
# 1. Tag format incorrect
git tag -l  # Should be v*.*.* format

# 2. Chart.yaml version mismatch
grep version ros-ocp/Chart.yaml

# 3. Permissions
# Check GitHub Actions permissions in repository settings
```

---

## Next Steps

- **Scripts Reference**: See [Scripts README](../scripts/README.md)
- **Installation**: See [Installation Guide](installation.md)
- **Configuration**: See [Configuration Guide](configuration.md)

---

**Related Documentation:**
- [Installation Guide](installation.md)
- [Platform Guide](platform-guide.md)
- [Scripts Reference](../scripts/README.md)

