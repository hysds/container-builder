#!/bin/bash
if (( $# < 3 ))
then
    echo "[ERROR] Build script requires REPO and TAG"
    exit 1
fi
#Setup input variables
DIR=$(dirname ${0})
REPO="${1}"
TAG="${2}"
STORAGE="${3}"
shift
shift
shift

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
${DIR}/validate.py docker/
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
            docker rmi -f ${PREV_ID}
        fi
        #Build container
        echo "[CI] Build for: ${PRODUCT} and file ${NAME}"
        #Build docker container
        echo " docker build --rm --force-rm -f docker/${dockerfile} -t ${PRODUCT} $@ ."
        docker build --rm --force-rm -f docker/${dockerfile} -t ${PRODUCT} "$@" .
        if (( $? != 0 ))
        then
            echo "[ERROR] Failed to build docker container for: ${PRODUCT}" 1>&2
            exit 4
        fi
        #Save out the docker image
        docker save -o ./${TAR} ${PRODUCT}
        if (( $? != 0 ))
        then
            echo "[ERROR] Failed to save docker container for: ${PRODUCT}" 1>&2
            exit 5
        fi
        #GZIP it
        pigz -f ./${TAR}
        if (( $? != 0 ))
        then
            echo "[ERROR] Failed to GZIP container for: ${PRODUCT}" 1>&2
            exit 6
        fi
        # get sha256 digest
        DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' ${PRODUCT} | cut -d'@' -f 2)
        ${DIR}/container-met.py ${PRODUCT} ${TAG} ${GZ} ${STORAGE} ${DIGEST}
        if (( $? != 0 ))
        then
            echo "[ERROR] Failed to make metadata and store container for: ${PRODUCT}" 1>&2
            exit 7
        fi
    fi
    containers[${NAME}]=${PRODUCT}
    #Attempt to remove dataset
    rm -f ${GZ}
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
    ${DIR}/job-met.py docker/${specification} ${cont} ${TAG}
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
    ${DIR}/io-met.py docker/${wiring} ${spec} ${TAG}
    if (( $? != 0 ))
    then
        echo "[ERROR] Failed to create metadata and ingest hysds-io for: ${PRODUCT}" 1>&2
        exit 3
    fi
done
exit 0
