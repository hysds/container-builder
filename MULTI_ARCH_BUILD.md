# Multi-Architecture Container Support

## Overview

The `container-met.py` script now supports registering containers for multiple architectures (x86_64 and ARM64) by accepting an optional ARM64 tarball parameter. This enables HySDS workers to automatically download and load the correct container image based on their architecture.

## Backward Compatibility

✅ **Default behavior unchanged**: If ARM64 tarball is not provided, registers x86_64 only (existing behavior)
✅ **Existing invocations work**: No changes needed to existing CI/CD pipelines
✅ **Legacy `url` field preserved**: Single URL field maintained for backward compatibility

## Usage

### Registering x86_64 Container Only (Default)

```bash
./container-met.py \
  container-name:tag \
  1.0.0 \
  container-name-tag.tar.gz \
  s3://bucket \
  sha256:digest \
  http://mozart-rest-url
```

**What This Does:**
- Uploads x86_64 tarball to storage (S3/local)
- Registers container metadata with Mozart
- Sets `url` field to x86_64 tarball URL
- Sets `urls` field with x86_64 mappings only

### Registering Multi-Architecture Container (x86_64 + ARM64)

```bash
./container-met.py \
  container-name:tag \
  1.0.0 \
  container-name-tag.tar.gz \
  s3://bucket \
  sha256:digest \
  http://mozart-rest-url \
  container-name-tag-arm64.tar.gz
```

**What This Does:**
- Uploads **both** x86_64 and ARM64 tarballs to storage
- Registers container metadata with Mozart
- Sets `url` field to x86_64 tarball URL (backward compatibility)
- Sets `urls` field with architecture-specific mappings:
  - `x86_64` / `amd64` → x86_64 tarball URL
  - `arm64` / `aarch64` → ARM64 tarball URL

## Arguments

```bash
container-met.py <ident> <version> <product> <repo> <digest> <mozart_url> [product_arm64]
```

| Argument | Required | Description | Example |
|----------|----------|-------------|----------|
| `ident` | Yes | Container name and tag | `container-name:tag` |
| `version` | Yes | Container version | `1.0.0` |
| `product` | Yes | x86_64 tarball filename | `container-name-tag.tar.gz` |
| `repo` | Yes | Storage URL (S3 or local) | `s3://bucket` or `/path/to/storage` |
| `digest` | Yes | Container image digest | `sha256:abc123...` |
| `mozart_url` | Yes | Mozart REST API URL | `http://mozart:8888/api/v0.2` |
| `product_arm64` | **Optional** | ARM64 tarball filename | `container-name-tag-arm64.tar.gz` |

## Metadata Schema

### Container Metadata Registered with Mozart

**Single Architecture (x86_64 only):**
```json
{
  "name": "container-name:tag",
  "version": "1.0.0",
  "url": "s3://bucket/container-name-tag.tar.gz",
  "urls": "{
    \"x86_64\": \"s3://bucket/container-name-tag.tar.gz\",
    \"amd64\": \"s3://bucket/container-name-tag.tar.gz\"
  }",
  "digest": "sha256:...",
  "resource": "container"
}
```

**Multi-Architecture (x86_64 + ARM64):**
```json
{
  "name": "container-name:tag",
  "version": "1.0.0",
  "url": "s3://bucket/container-name-tag.tar.gz",
  "urls": "{
    \"x86_64\": \"s3://bucket/container-name-tag.tar.gz\",
    \"amd64\": \"s3://bucket/container-name-tag.tar.gz\",
    \"arm64\": \"s3://bucket/container-name-tag-arm64.tar.gz\",
    \"aarch64\": \"s3://bucket/container-name-tag-arm64.tar.gz\"
  }",
  "digest": "sha256:...",
  "resource": "container"
}
```

**Key Points:**
- `url` field: Single URL for backward compatibility (always x86_64)
- `urls` field: JSON string containing architecture-specific URL mappings
- Both `x86_64` and `amd64` map to the same x86_64 tarball
- Both `arm64` and `aarch64` map to the same ARM64 tarball

## Jenkins/CI Integration

### Example: Register x86_64 Container Only (Backward Compatible)

```groovy
// Existing code - no changes needed
sh """
    IMAGE="container-\${REPO}:${TAG}"
    TARBALL="\${IMAGE//:\//_}.tar.gz"
    DIGEST=\$(docker inspect --format='{{.Id}}' \${IMAGE})
    
    ~/verdi/ops/container-builder/container-met.py \\
        \${IMAGE} \\
        ${TAG} \\
        \${TARBALL} \\
        \${STORAGE_URL} \\
        \${DIGEST} \\
        \${MOZART_REST_URL}
"""
```

### Example: Register Multi-Architecture Container

```groovy
sh """
    IMAGE="container-\${REPO}:${TAG}"
    TARBALL_X86="\${IMAGE//:\//_}.tar.gz"
    TARBALL_ARM64="\${IMAGE//:\//_}-arm64.tar.gz"
    DIGEST=\$(docker inspect --format='{{.Id}}' \${IMAGE})
    
    # Register both architectures
    ~/verdi/ops/container-builder/container-met.py \\
        \${IMAGE} \\
        ${TAG} \\
        \${TARBALL_X86} \\
        \${STORAGE_URL} \\
        \${DIGEST} \\
        \${MOZART_REST_URL} \\
        \${TARBALL_ARM64}
"""
```

### Example: Complete Multi-Platform Build and Register

```groovy
stage('Build and Register Multi-Arch Container') {
    steps {
        sh """
            IMAGE="container-\${REPO}:${TAG}"
            TARBALL_X86="\${IMAGE//:\//_}.tar.gz"
            TARBALL_ARM64="\${IMAGE//:\//_}-arm64.tar.gz"
            
            # Build x86_64 image
            docker buildx build --platform linux/amd64 -t \${IMAGE} --load .
            docker save \${IMAGE} | gzip > \${TARBALL_X86}
            
            # Build ARM64 image
            docker buildx build --platform linux/arm64 -t \${IMAGE} --load .
            docker save \${IMAGE} | gzip > \${TARBALL_ARM64}
            
            # Get digest from x86_64 image
            DIGEST=\$(docker inspect --format='{{.Id}}' \${IMAGE})
            
            # Register both architectures
            ~/verdi/ops/container-builder/container-met.py \\
                \${IMAGE} \\
                ${TAG} \\
                \${TARBALL_X86} \\
                \${STORAGE_URL} \\
                \${DIGEST} \\
                \${MOZART_REST_URL} \\
                \${TARBALL_ARM64}
        """
    }
}
```

## How It Works

### Upload Process
1. **x86_64 tarball**: Always uploaded to storage (required)
2. **ARM64 tarball**: Uploaded only if provided (optional)
3. **Storage**: Uses `osaka.main.put()` to upload to S3 or local storage

### Metadata Registration
1. **Constructs metadata dict** with name, version, url, digest, resource
2. **Adds `urls` field** as JSON string with architecture mappings
3. **POSTs to Mozart API** at `/container/add` endpoint
4. **Mozart stores** in Elasticsearch containers index

### Worker Container Selection
When a HySDS worker needs to load a container:
1. Worker reads `container_image_urls` from job metadata
2. Detects current architecture using `platform.machine()`
3. Selects appropriate URL from `urls` mapping
4. Downloads and loads architecture-specific tarball
5. Falls back to `url` field if `urls` not available (backward compatibility)

## Tarball Naming Convention

**x86_64 tarball** (no suffix for backward compatibility):
```
container-name-tag.tar.gz
```

**ARM64 tarball** (with `-arm64` suffix):
```
container-name-tag-arm64.tar.gz
```

## Requirements

### For container-met.py
- Python 3.x
- `requests` library
- `osaka` library (for S3/storage uploads)
- Mozart REST API accessible

### For Multi-Architecture Support (Full System)
- **Mozart**: Updated API endpoints to accept `urls` parameter
- **HySDS**: Updated container loading logic to use architecture-specific URLs
- **hysds_commons**: Updated job resolution to pass `container_image_urls`
- **Workers**: Must be running updated HySDS code

## Troubleshooting

### Error: "Metadata requires: ident version product repo digest mozart_url [product_arm64]"
**Cause**: Missing required arguments.  
**Solution**: Provide all 6 required arguments. The 7th (ARM64 tarball) is optional.

### Error: Upload fails to S3
**Cause**: Invalid S3 credentials or permissions.  
**Solution**: Ensure AWS credentials are configured and have write access to the bucket.

### Error: Mozart API POST fails
**Cause**: Mozart REST API is unreachable or returns error.  
**Solution**: 
- Verify Mozart URL is correct and accessible
- Check Mozart logs for API errors
- Ensure Mozart API endpoints are updated to accept `urls` parameter

### Worker downloads wrong architecture
**Cause**: Worker is running old HySDS code without multi-arch support.  
**Solution**: Update HySDS on workers and restart celery workers:
```bash
cd /home/ops/verdi/ops/hysds
git pull
pip install -e .
supervisorctl restart all
```

### Container registered but `urls` field missing in Mozart
**Cause**: Mozart API not updated to handle `urls` parameter.  
**Solution**: Deploy updated Mozart code with multi-architecture support.

## Migration Guide

### Existing Pipelines
No changes required! The script is fully backward compatible. Existing 6-argument invocations continue to work.

### Adding ARM64 Support to Existing Container
1. Build ARM64 tarball (using Docker Buildx or native ARM64 host)
2. Add ARM64 tarball as 7th argument to `container-met.py`
3. Script automatically uploads both tarballs and registers with architecture mappings

### System-Wide Multi-Architecture Deployment

**Phase 1: Update Core Components**
1. Deploy updated `container-builder` (this repo)
2. Deploy updated `mozart` with `urls` parameter support
3. Deploy updated `hysds` with architecture-aware container loading
4. Deploy updated `hysds_commons` with `container_image_urls` support

**Phase 2: Update Workers**
1. Update HySDS code on all workers
2. Restart celery workers to load new code
3. Verify workers can read architecture from `platform.machine()`

**Phase 3: Register Multi-Arch Containers**
1. Build both x86_64 and ARM64 tarballs
2. Register using updated `container-met.py` with both tarballs
3. Workers automatically select correct architecture

### Verification

Check that multi-arch metadata is registered correctly:
```bash
curl -X GET "http://mozart:9200/containers/_doc/container-name:tag?pretty"
```

Should show both `url` and `urls` fields in the response.
