#!/bin/bash
if (( $# < 6 ))
then
    echo "[ERROR] Build script requires REPO and TAG"
    exit 1
fi
#Setup input variables
DIR=$(dirname ${0})
REPO="${1}"
TAG="${2}"
STORAGE="${3}"
MOZART_REST_URL="${4}"
GRQ_REST_URL="${5}"
SKIP_PUBLISH="${6}"
CONTAINER_REGISTRY="${7}"
shift
shift
shift
shift
shift
shift
shift

# Default platform (backward compatible)
PLATFORM="linux/amd64"
USE_BUILDX=0

# Parse remaining arguments for --platform flag
while [[ $# -gt 0 ]]; do
    case $1 in
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        --platform=*)
            PLATFORM="${1#*=}"
            shift
            ;;
        *)
            # Keep other arguments for docker build
            BUILD_ARGS="${BUILD_ARGS} $1"
            shift
            ;;
    esac
done

# Check if multi-platform build is requested
if [[ "$PLATFORM" == *","* ]]; then
    USE_BUILDX=1
    echo "[CI] Multi-platform build requested: ${PLATFORM}"
    echo "[CI] Will use docker buildx for multi-platform support"
else
    echo "[CI] Single platform build: ${PLATFORM}"
fi

#An array to map containers to annotations
declare -A containers
declare -A specs

# detect branch or tag
IS_TAG=0
DESCRIBED_TAG=$(git describe --exact-match --tags HEAD)
if (( $? == 0 ))
then
    IS_TAG=1
fi
echo "[CI] Is checkout a tag: ${IS_TAG} ${DESCRIBED_TAG}"

#Get last log message
LAST_LOG=$(git log -1)
echo "[CI] Last log: ${LAST_LOG}"

# extract any flags from last log
SKIP_IMAGE_BUILD_FLAG=0
GREP_SKIP_IMAGE_BUILD=$(echo $LAST_LOG | grep -i SKIP_IMAGE_BUILD)
if (( $? == 0 ))
then
    SKIP_IMAGE_BUILD_FLAG=1
fi
echo "[CI] Skip image build flag: ${SKIP_IMAGE_BUILD_FLAG}"

# skip image build? only if checkout is a branch and SKIP_IMAGE_BUILD is set
SKIP_IMAGE_BUILD=0
if [[ $IS_TAG -eq 0 ]] && [[ $SKIP_IMAGE_BUILD_FLAG -eq 1 ]]
then
    SKIP_IMAGE_BUILD=1
    echo "[CI] Image build will be skipped."
fi

#Use git to cleanly remove any artifacts
git clean -ffdq -e repos
if (( $? != 0 ))
then
   echo "[ERROR] Failed to force-clean the git repo"
   exit 3
fi

#Run the validation script here
${DIR}/../hysds_commons/hysds_commons/validate.py docker/
if (( $? != 0 ))
then
    echo "[ERROR] Failed to validate hysds-io and job-spec JSON files under ${REPO}/docker. Cannot continue."
    exit 1
fi
if [ -f docker/setup.sh ]
then
    docker/setup.sh
    if (( $? != 0 ))
    then
        echo "[ERROR] Failed to run docker/setup.sh"
        exit 2
    fi
fi
# Loop accross all Dockerfiles, build and ingest them
for dockerfile in docker/Dockerfile*
do
    dockerfile=${dockerfile#docker/}
    #Get the name for this container, from repo or annotation to Dockerfile
    NAME=${REPO}
    if [[ "${dockerfile}" != "Dockerfile" ]]
    then
        NAME=${dockerfile#Dockerfile.}
    fi
    #Setup container build items
    PRODUCT="container-${NAME}:${TAG}"
    #Docker tags must be lower case
    PRODUCT=${PRODUCT,,}
    TAR="${PRODUCT}.tar"
    GZ="${TAR}.gz" 
    #Remove previous container if exists
    PREV_ID=$(docker images -q $PRODUCT)
    if (( ${SKIP_IMAGE_BUILD} == 0 )); then
        if [[ ! -z "$PREV_ID" ]]
        then
            echo "[CI] Removing current image for ${PRODUCT}: ${PREV_ID}"
            docker system prune -f
            docker rmi -f $(docker images | grep $PREV_ID | awk '{print $1":"$2}')
        fi
        #Build container
        echo "[CI] Build for: ${PRODUCT} and file ${NAME}"
        
        if (( ${USE_BUILDX} == 1 )); then
            # Multi-platform build - build each architecture separately to create tarballs
            echo "[CI] Building multi-platform image: ${PLATFORM}"
            echo "[CI] Will build each architecture separately to create individual tarballs"
            
            # Split platforms and build each one
            IFS=',' read -ra PLATFORMS <<< "$PLATFORM"
            for plat in "${PLATFORMS[@]}"; do
                plat=$(echo "$plat" | xargs) # trim whitespace
                echo "[CI] Building for platform: ${plat}"
                
                # Determine architecture suffix for tarball naming
                ARCH_SUFFIX=""
                if [[ "$plat" == *"arm64"* ]]; then
                    ARCH_SUFFIX="-arm64"
                fi
                
                # Build for this specific platform
                PLATFORM_PRODUCT="${PRODUCT}${ARCH_SUFFIX}"
                PLATFORM_TAR="${PLATFORM_PRODUCT}.tar"
                PLATFORM_GZ="${PLATFORM_TAR}.gz"
                
                echo " docker buildx build --platform ${plat} --rm --force-rm -f docker/${dockerfile} -t ${PRODUCT} ${BUILD_ARGS} --load ."
                docker buildx build --platform ${plat} --rm --force-rm -f docker/${dockerfile} -t ${PRODUCT} ${BUILD_ARGS} --load .
                if (( $? != 0 ))
                then
                    echo "[ERROR] Failed to build docker container for platform ${plat}: ${PRODUCT}" 1>&2
                    exit 4
                fi
                
                # Save this platform's image to tarball
                if [ "$SKIP_PUBLISH" != "skip" ]; then
                    echo "[CI] Saving ${plat} image to ${PLATFORM_TAR}"
                    docker save -o ./${PLATFORM_TAR} ${PRODUCT}
                    if (( $? != 0 ))
                    then
                        echo "[ERROR] Failed to save docker container for platform ${plat}: ${PRODUCT}" 1>&2
                        exit 5
                    fi
                    
                    # GZIP it
                    pigz -f ./${PLATFORM_TAR}
                    if (( $? != 0 ))
                    then
                        echo "[ERROR] Failed to GZIP container for platform ${plat}: ${PRODUCT}" 1>&2
                        exit 6
                    fi
                    
                    echo "[CI] Created tarball: ${PLATFORM_GZ}"
                fi
                
                # Push to registry with platform-specific tag
                if [[ ! -z "$CONTAINER_REGISTRY" ]]; then
                    REGISTRY_TAG="${CONTAINER_REGISTRY}/${PRODUCT}${ARCH_SUFFIX}"
                    echo "[CI] Pushing ${plat} image to registry: ${REGISTRY_TAG}"
                    docker tag ${PRODUCT} ${REGISTRY_TAG}
                    docker push ${REGISTRY_TAG}
                fi
            done
            
            # Now create multi-platform manifest in registry
            if [[ ! -z "$CONTAINER_REGISTRY" ]]; then
                echo "[CI] Creating multi-platform manifest: ${CONTAINER_REGISTRY}/${PRODUCT}"
                
                # Verify multiarch builder exists (should be pre-installed on Jenkins agent)
                if ! docker buildx ls | grep -q "multiarch"; then
                    echo "[ERROR] multiarch builder not found. Please install it on the Jenkins agent:" 1>&2
                    echo "[ERROR]   docker buildx create --name multiarch --driver docker-container --bootstrap" 1>&2
                    echo "[ERROR] See MULTI_ARCH_BUILD.md for details." 1>&2
                    exit 4
                fi
                
                echo "[CI] Using multiarch builder for multi-platform manifest"
                MANIFEST_CMD="docker buildx build --builder multiarch --platform ${PLATFORM} --rm --force-rm -f docker/${dockerfile} -t ${CONTAINER_REGISTRY}/${PRODUCT} ${BUILD_ARGS} --push ."
                echo " ${MANIFEST_CMD}"
                eval ${MANIFEST_CMD}
                if (( $? != 0 ))
                then
                    echo "[ERROR] Failed to create multi-platform manifest" 1>&2
                    exit 4
                fi
                echo "[CI] Multi-platform manifest created successfully"
            fi
            
            # Skip the normal save/push logic since we handled it above
            USE_BUILDX=2
        else
            # Single platform build using standard docker build
            echo "[CI] Building single platform image: ${PLATFORM}"
            echo " docker build --platform ${PLATFORM} --rm --force-rm -f docker/${dockerfile} -t ${PRODUCT} ${BUILD_ARGS} ."
            docker build --platform ${PLATFORM} --rm --force-rm -f docker/${dockerfile} -t ${PRODUCT} ${BUILD_ARGS} .
            if (( $? != 0 ))
            then
                echo "[ERROR] Failed to build docker container for: ${PRODUCT}" 1>&2
                exit 4
            fi
        fi
        
        if [ "$SKIP_PUBLISH" != "skip" ];then
            if (( ${USE_BUILDX} == 2 )); then
                # Multi-platform build already created tarballs and pushed to registry
                echo "[CI] Multi-platform build complete - tarballs and registry images created"
            else
                #Save out the docker image
                docker save -o ./${TAR} ${PRODUCT}
                if (( $? != 0 ))
                then
                    echo "[ERROR] Failed to save docker container for: ${PRODUCT}" 1>&2
                    exit 5
                fi
                 #If CONTAINER_REGISTRY is defined, push to registry. Otherwise, gzip it.
                if [[ ! -z "$CONTAINER_REGISTRY" ]]
                then
                    echo "[CI] Pushing docker container ${PRODUCT} to ${CONTAINER_REGISTRY}"
                    docker tag ${PRODUCT} ${CONTAINER_REGISTRY}/${PRODUCT}
                    docker push ${CONTAINER_REGISTRY}/${PRODUCT}
                fi
                #GZIP it
                pigz -f ./${TAR}
                if (( $? != 0 ))
                then
                    echo "[ERROR] Failed to GZIP container for: ${PRODUCT}" 1>&2
                    exit 6
                fi
            fi
        else
            echo "Skip publishing"
        fi

        # get image digest (sha256)
        digest=$(docker inspect --format='{{index .Id}}' ${PRODUCT} | cut -d'@' -f 2)
        ${DIR}/container-met.py ${PRODUCT} ${TAG} ${GZ} ${STORAGE} ${digest} ${MOZART_REST_URL}
        if (( $? != 0 ))
        then
            echo "[ERROR] Failed to make metadata and store container for: ${PRODUCT}" 1>&2
            exit 7
        fi
    fi
    containers[${NAME}]=${PRODUCT}
    #HC-70 change
    if [ "$SKIP_PUBLISH" != "skip" ];then
        #Attempt to remove dataset
        rm -f ${GZ}
    fi
done
#Loop across job specification
for specification in docker/job-spec.json*
do
    specification=${specification#docker/}
    #Get the name for this container, from repo or annotation to Dockerfile
    NAME=${REPO}
    if [[ "${specification}" != "job-spec.json" ]]
    then
        NAME=${specification#job-spec.json.}
    fi
    #Setup container build items
    PRODUCT="job-${NAME}:${TAG}"    
    echo "[CI] Build for: ${PRODUCT} and file ${NAME}"
    cont=${containers[${NAME}]}
    if [ -z "${cont}" ]
    then
        cont=${containers[${REPO}]}
    fi
    echo "Running Job-Met on: ${cont} docker/${specification} ${TAG} ${PRODUCT}"
    ${DIR}/job-met.py docker/${specification} ${cont} ${TAG} ${MOZART_REST_URL} ${STORAGE}
    if (( $? != 0 ))
    then
        echo "[ERROR] Failed to create metadata and ingest job-spec for: ${PRODUCT}" 1>&2
        exit 3
    fi
    specs[${NAME}]=${PRODUCT}
done
#Loop across job specification
let iocnt=`ls docker/hysds-io.json* | wc -l`
if (( $iocnt == 0 ))
then
    exit 0
fi
for wiring in docker/hysds-io.json*
do
    wiring=${wiring#docker/}
    #Get the name for this container, from repo or annotation to Dockerfile
    NAME=${REPO}
    if [[ "${wiring}" != "hysds-io.json" ]]
    then
        NAME=${wiring#hysds-io.json.}
    fi
    #Setup container build items
    PRODUCT="hysds-io-${NAME}:${TAG}"    
    echo "[CI] Build for: ${PRODUCT} and file ${NAME}"
    spec=${specs[${NAME}]}
    if [ -z "${cont}" ]
    then
        spec=${specs[${REPO}]}
    fi
    echo "Running IO-Met on: ${cont} docker/${wiring} ${TAG} ${PRODUCT}"
    ${DIR}/io-met.py docker/${wiring} ${spec} ${TAG} ${MOZART_REST_URL} ${GRQ_REST_URL}
    if (( $? != 0 ))
    then
        echo "[ERROR] Failed to create metadata and ingest hysds-io for: ${PRODUCT}" 1>&2
        exit 3
    fi
done
exit 0
