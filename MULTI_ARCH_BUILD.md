# Multi-Architecture Container Builds

## Overview

The `build-container.bash` script now supports building containers for multiple architectures using the optional `--platform` argument.

## Backward Compatibility

✅ **Default behavior unchanged**: If `--platform` is not specified, builds for `linux/amd64` (x86_64) only
✅ **Existing invocations work**: No changes needed to existing CI/CD pipelines

## Usage

### Option 1: Build for x86_64 Only (Default)

```bash
# These are equivalent:
./build-container.bash ${REPO} ${BRANCH} ${STORAGE} --build-arg id=$UID --build-arg gid=$GID

./build-container.bash ${REPO} ${BRANCH} ${STORAGE} --build-arg id=$UID --build-arg gid=$GID --platform linux/amd64
```

### Option 2: Build for ARM64 Only

```bash
./build-container.bash ${REPO} ${BRANCH} ${STORAGE} --build-arg id=$UID --build-arg gid=$GID --platform linux/arm64
```

**Note**: Requires QEMU on x86_64 hosts (see Prerequisites below)

### Option 3: Build Multi-Platform Image (x86_64 + ARM64)

```bash
./build-container.bash ${REPO} ${BRANCH} ${STORAGE} --build-arg id=$UID --build-arg gid=$GID --platform linux/amd64,linux/arm64
```

**What This Does:**
- Builds **both architectures sequentially**
- Creates **two separate tarballs**:
  - `container-name:tag.tar.gz` (x86_64)
  - `container-name:tag-arm64.tar.gz` (ARM64)
- Pushes **individual images** to registry with architecture-specific tags
- Creates a **multi-platform manifest** in the registry (single tag that works on both architectures)

**Requirements:**
- Docker Buildx configured (see Prerequisites below)
- CONTAINER_REGISTRY set (for multi-platform manifest)

## Platform Argument Formats

The `--platform` argument accepts:

```bash
--platform linux/amd64              # x86_64 only
--platform linux/arm64              # ARM64 only
--platform linux/amd64,linux/arm64  # Multi-platform (both)
--platform=linux/arm64              # Alternative syntax
```

## Prerequisites

### For ARM64 Builds on x86_64 Host

Install QEMU for emulation:

```bash
sudo apt-get update
sudo apt-get install -y qemu-user-static binfmt-support
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

Verify:
```bash
docker run --rm --platform linux/arm64 alpine uname -m
# Should output: aarch64
```

### For Multi-Platform Builds (REQUIRED)

**⚠️ IMPORTANT**: The `multiarch` builder must be installed on each Jenkins agent before running multi-platform builds.

#### One-Time Setup on Jenkins Agent

SSH to the Jenkins agent as the `hysdsops` user and run:

```bash
# 1. Remove any existing broken builder (if applicable)
docker buildx rm multiarch 2>/dev/null || true

# 2. Create the multiarch builder with docker-container driver
docker buildx create --name multiarch --driver docker-container --bootstrap

# 3. Verify it was created successfully
docker buildx ls
# Should show:
# NAME/NODE        DRIVER/ENDPOINT                   STATUS    BUILDKIT   PLATFORMS
# multiarch*       docker-container
#  \_ multiarch0    \_ unix:///var/run/docker.sock   running   v0.x.x     linux/amd64, linux/arm64, ...

# 4. Inspect the builder to ensure it's functional
docker buildx inspect multiarch
# Should show Status: running and Platforms including linux/amd64 and linux/arm64

# 5. Set up QEMU for ARM64 emulation (if not already done)
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

#### Verification

After setup, verify the builder is working:

```bash
# Check builder exists and is running
docker buildx ls | grep multiarch

# Test a simple multi-platform build
docker buildx build --builder multiarch --platform linux/amd64,linux/arm64 -t test:multiarch - <<EOF
FROM alpine
RUN uname -m
EOF
```

#### Troubleshooting

**If the builder exists but is not functional:**
```bash
# Remove and recreate
docker buildx rm multiarch
docker buildx create --name multiarch --driver docker-container --bootstrap
```

**If you see "ERROR: existing instance for multiarch but no append mode":**
```bash
# The builder already exists, just verify it's working
docker buildx inspect multiarch
# If it shows Status: running, you're good to go
```

## Jenkins/CI Integration

### Using Updated Jenkins Configuration Files

The Jenkins configuration files (`config.xml` and `config-branch.xml`) have been updated with a **PLATFORM** choice parameter.

**When you create/update Jenkins jobs using these configs, users will see:**
- Dropdown parameter: **PLATFORM**
- Choices:
  - `linux/amd64` (x86_64 - default)
  - `linux/arm64` (ARM64)
  - `linux/amd64,linux/arm64` (Multi-platform)

**The parameter is automatically passed to the build script:**
```bash
~/verdi/ops/container-builder/build-container.bash ${REPO} ${BRANCH} ${STORAGE} \
    --build-arg id=$UID --build-arg gid=$GID --platform $PLATFORM
```

### Example: Build x86_64 Only (Backward Compatible)

```groovy
// Existing code - no changes needed
sh """
    BRANCH="\${GIT_BRANCH##*/}"
    REPO="\${GIT_URL#*://*/}"
    REPO="\${REPO%.git}"
    REPO="\${REPO//\\//_}"
    STORAGE="\$STORAGE_URL"
    export GIT_OAUTH_TOKEN="\$GIT_OAUTH_TOKEN"
    ~/verdi/ops/container-builder/build-container.bash \${REPO} \${BRANCH} \${STORAGE} --build-arg id=$UID --build-arg gid=$GID
"""
```

### Example: Build ARM64 with Parameter

```groovy
parameters {
    choice(name: 'PLATFORM', choices: ['linux/amd64', 'linux/arm64'], description: 'Target platform')
}

stages {
    stage('Build Container') {
        steps {
            sh """
                BRANCH="\${GIT_BRANCH##*/}"
                REPO="\${GIT_URL#*://*/}"
                REPO="\${REPO%.git}"
                REPO="\${REPO//\\//_}"
                STORAGE="\$STORAGE_URL"
                export GIT_OAUTH_TOKEN="\$GIT_OAUTH_TOKEN"
                ~/verdi/ops/container-builder/build-container.bash \${REPO} \${BRANCH} \${STORAGE} \\
                    --build-arg id=$UID --build-arg gid=$GID \\
                    --platform ${params.PLATFORM}
            """
        }
    }
}
```

### Example: Build Both Architectures (Separate Jobs)

**Job 1: Build x86_64**
```groovy
sh """
    ~/verdi/ops/container-builder/build-container.bash \${REPO} \${BRANCH} \${STORAGE} \\
        --build-arg id=$UID --build-arg gid=$GID \\
        --platform linux/amd64
"""
```

**Job 2: Build ARM64**
```groovy
sh """
    ~/verdi/ops/container-builder/build-container.bash \${REPO} \${BRANCH} \${STORAGE} \\
        --build-arg id=$UID --build-arg gid=$GID \\
        --platform linux/arm64
"""
```

## How It Works

### Single Platform Build
- Uses standard `docker build` command
- Adds `--platform` flag to specify target architecture
- Fast for native architecture, slower with QEMU emulation for non-native

### Multi-Platform Build
- Detects comma in platform string (e.g., `linux/amd64,linux/arm64`)
- Automatically switches to `docker buildx build`
- Creates a single image manifest that works on both architectures
- Uses `--load` flag to load the image into local Docker daemon

## Container Naming

Container names remain unchanged regardless of platform:
```
container-${REPO}:${TAG}
```

The platform information is stored in the image manifest, not the tag name.

## Limitations

### Multi-Platform Builds
- **Sequential builds**: Architectures are built one after another (not parallel)
- **Longer build time**: Takes sum of both architecture build times
- **Requires CONTAINER_REGISTRY**: For creating the multi-platform manifest
- **Requires Docker Buildx**: Must be configured with `docker-container` driver

### Performance
- **ARM64 on x86_64 via QEMU**: 5-10x slower than native
- **Multi-platform builds**: Sequential, so total time = x86_64 time + ARM64 time

### Build Time Comparison
Example for a typical container:

| Option | Time | Tarballs | Multi-Platform Manifest |
|--------|------|----------|------------------------|
| `linux/amd64` only | ~5 min | ✅ 1 tarball | ❌ |
| `linux/arm64` only | ~30 min (QEMU) | ✅ 1 tarball | ❌ |
| `linux/amd64,linux/arm64` | ~35 min (sequential) | ✅ 2 tarballs | ✅ |
| Two separate jobs (parallel) | ~30 min (parallel) | ✅ 2 tarballs | ❌ (manual) |

## Troubleshooting

### Error: "exec format error"
**Cause**: QEMU is not installed or not configured.  
**Solution**: See Prerequisites section for QEMU installation.

### Error: "unknown flag: --platform"
**Cause**: Docker version is too old.  
**Solution**: Requires Docker 18.09+ for `--platform` flag. Upgrade Docker.

### Error: "Multi-platform build is not supported for the docker driver"
**Cause**: Docker Buildx is not available or the default driver is being used.  
**Solution**: Install Docker 19.03+ and create the `multiarch` builder (see Prerequisites section).

### Error: "multiarch builder not found"
**Cause**: The `multiarch` builder has not been created on the Jenkins agent.  
**Solution**: Follow the one-time setup instructions in the Prerequisites section to create the builder.

### Multi-platform build creates two tarballs
This is **expected and desired**! When you build with `linux/amd64,linux/arm64`, you get:
- `container-name:tag.tar.gz` (x86_64)
- `container-name:tag-arm64.tar.gz` (ARM64)

Both tarballs are created automatically in a single job run. This allows you to distribute both architectures separately.

## Migration Guide

### Existing Pipelines
No changes required! The script is fully backward compatible.

### Adding ARM64 Support
1. Install QEMU on build host (one-time setup)
2. Add `--platform linux/arm64` to build command
3. Run as separate job or with parameter selection

### Creating Multi-Platform Images
1. **Install the `multiarch` builder on Jenkins agent** (one-time setup - see Prerequisites section)
2. Install QEMU on build host (one-time setup)
3. Use `--platform linux/amd64,linux/arm64`
4. Ensure `CONTAINER_REGISTRY` is set for manifest creation
