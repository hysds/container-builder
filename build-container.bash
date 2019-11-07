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

COLON=":"

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
        #Build docker container
        echo " docker build --rm --force-rm -f docker/${dockerfile} -t ${PRODUCT} $@ ."
        docker build --rm --force-rm -f docker/${dockerfile} -t ${PRODUCT} "$@" .
        if (( $? != 0 ))
        then
            echo "[ERROR] Failed to build docker container for: ${PRODUCT}" 1>&2
            exit 4
        fi
        
        if [ "$SKIP_PUBLISH" != "skip" ];then
            #Save out the docker image
            docker save -o ./${TAR} ${PRODUCT}
            if (( $? != 0 ))
            then
                echo "[ERROR] Failed to save docker container for: ${PRODUCT}" 1>&2
                exit 5
            fi
            #If CONTAINER_REGISTRY is defined, push to registry. Otherwise, gzip it.
            # if [[ ! -z "$CONTAINER_REGISTRY" ]]
            # then
            #     echo "[CI] Pushing docker container ${PRODUCT} to ${CONTAINER_REGISTRY}"
            #     docker tag ${PRODUCT} ${CONTAINER_REGISTRY}/${PRODUCT}
            #     docker push ${CONTAINER_REGISTRY}/${PRODUCT}
            # fi
            #GZIP it
            pigz -f ./${TAR}
            if (( $? != 0 ))
            then
                echo "[ERROR] Failed to GZIP container for: ${PRODUCT}" 1>&2
                exit 6
            fi
        else
            echo "Skip publishing"
        fi


        # in the case of singularity
        # to do: mkdir of these if not exist and chown to ops:ops (sudo chown -R ops:ops /data)
        S_IMG_DIR="/data/data/singularity/simg"
        S_SANDBOX_DIR="/data/data/singularity/sandbox"
        # clean up image directory
        sudo rm -f ${S_IMG_DIR}/container*.simg
        echo "[CI] Build singularity image for ${PRODUCT}"
        SINGULARITY_OPTIONS="-v /var/run/docker.sock:/var/run/docker.sock --privileged -t --rm -v ${S_IMG_DIR}:/output"
        ### echo ${SINGULARITY_OPTIONS}
        docker run ${SINGULARITY_OPTIONS} singularityware/docker2singularity ${PRODUCT}

        echo "[CI] Convert singularity image into sandbox"
        sudo rm -rf ${S_SANDBOX_DIR}/*simg*
        for simg_file in ${S_IMG_DIR}/*.simg # there is only one simg; this for loop is just for getting its name
        do
          simg_file=${simg_file#${S_IMG_DIR}/}
          echo "S_SANDBOX_DIR: ${S_SANDBOX_DIR}"
          echo "simg_file: ${simg_file}"
          echo "S_IMG_DIR ${S_IMG_DIR}"
          echo "S_PRODUCT: ${S_PRODUCT}"
          echo "command: singularity build --sandbox ${S_SANDBOX_DIR}/${simg_file} ${S_IMG_DIR}/${simg_file}"
          singularity build --sandbox ${S_SANDBOX_DIR}/${simg_file} ${S_IMG_DIR}/${simg_file}

          # singularity build creates some files that are not writable by user, which is problematic
          echo "[CI] chmod -R u+w ${S_SANDBOX_DIR}/${simg_file}"
          chmod -R u+w ${S_SANDBOX_DIR}/${simg_file}

          echo "[CI] GZIP singularity sandbox"
          S_GZ="${simg_file}.tar.gz"
          ### tar cf - ${S_SANDBOX_DIR}/${simg_file} | pigz > ./${S_GZ}
          PWD1=$PWD
          echo "PWD1: ${PWD1}"
          cd ${S_SANDBOX_DIR}
          tar cf - ${simg_file} | pigz > ${PWD1}/${S_GZ}
          cd ${PWD1}
        done


        # get image digest (sha256)
        digest=$(docker inspect --format='{{index .Id}}' ${PRODUCT} | cut -d'@' -f 2)

        ${DIR}/container-met.py ${PRODUCT} ${TAG} ${GZ} ${STORAGE} ${digest} ${MOZART_REST_URL}
        if (( $? != 0 ))
        then
           echo "[ERROR] Failed to make metadata and store container for: ${PRODUCT}" 1>&2
           exit 7
        fi


        # get image digest (sha256) for singularity sandbox tar ball
        S_TAG="${TAG}_singularity"
        ### if [ "${TAG#*$COLON}" = "$TAG" ]; then  # does not contain ":"
        ###   S_TAG="singularity_${TAG}"
        ### else  # contains ":"
        ###   S_TAG="${TAG/$COLON/_singularity$COLON}"
        ### fi

        S_PRODUCT="${PRODUCT}_singularity"
        ### if [ "${PRODUCT#*$COLON}" = "$PRODUCT" ]; then  # does not contain ":"
        ###   S_PRODUCT="${PRODUCT}_singularity"
        ### else  # contains ":"
        ###   S_PRODUCT="${PRODUCT/$COLON/_singularity$COLON}"
        ### fi

        echo "before calling container-met.py for singularity"
        echo "S_PRODUCT: ${S_PRODUCT}"
        echo "S_TAG: ${S_TAG}"
        echo "S_GZ: ${S_GZ}"
        echo "STORAGE: ${STORAGE}"
        echo "digest: ${digest}"
        echo "MOZART_REST_URL: ${MOZART_REST_URL}"

        ${DIR}/container-met.py ${S_PRODUCT} ${S_TAG} ${S_GZ} ${STORAGE} ${digest} ${MOZART_REST_URL}
        if (( $? != 0 ))
        then
            echo "[ERROR] Failed to make metadata and store container for: ${PRODUCT}" 1>&2
            exit 8
        fi
    fi

    echo "****** NAME: $NAME"
    echo "****** S_PRODUCT: $S_PRODUCT"
    containers[${NAME}]=${PRODUCT}
    containers["${NAME}_singularity"]=${S_PRODUCT}
    echo "****** containers[${NAME}]: ${containers[${NAME}]}"
    echo "****** containers["${NAME}_singularity"]: ${containers["${NAME}_singularity"]}"
    #HC-70 change
    if [ "$SKIP_PUBLISH" != "skip" ];then
        #Attempt to remove dataset
        rm -f ${GZ}
        rm -rf ${S_SANDBOX_DIR}/${simg_file}
        rm -f ${S_GZ}
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
    echo "****** cont: $cont"

    s_cont=${containers["${NAME}_singularity"]}
    if [ -z "${s_cont}" ]
    then
        s_cont=${containers["${REPO}_singularity"]}
    fi
    echo "****** s_cont: $s_cont"

    # do not create the docker job
    ### echo "Running Job-Met on: ${cont} docker/${specification} ${TAG} ${PRODUCT}"
    ### ${DIR}/job-met.py docker/${specification} ${cont} ${TAG} ${MOZART_REST_URL} ${STORAGE}
    ### if (( $? != 0 ))
    ### then
    ###     echo "[ERROR] Failed to create metadata and ingest job-spec for: ${PRODUCT}" 1>&2
    ###     exit 3
    ### fi

    echo "****** before calling job-met for singularity ******"
    echo "specification: ${specification}"
    echo "s_cont: ${s_cont}"
    echo "S_TAG: ${S_TAG}"
    echo "MOZART_REST_URL: ${MOZART_REST_URL}"
    echo "Running Job-Met on: ${s_cont} docker/${specification} ${S_TAG} ${PRODUCT}"
    # it seems that the ${TAG} being used here needs to be the same as job spec
    # for the io-met.py call below to find this job
    ### ${DIR}/job-met.py docker/${specification} ${s_cont} ${S_TAG} ${MOZART_REST_URL} ${STORAGE}
    ${DIR}/job-met.py docker/${specification} ${s_cont} ${TAG} ${MOZART_REST_URL} ${STORAGE}
    if (( $? != 0 ))
    then
        echo "[ERROR] Failed to create metadata and ingest job-spec for: ${PRODUCT}" 1>&2
        exit 3
    fi

    specs[${NAME}]=${PRODUCT}
    specs["${NAME}_singularity"]=${S_PRODUCT}
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
    if [ -z "${spec}" ]
    then
        spec=${specs[${REPO}]}
    fi
    ### s_spec=${specs["${NAME}_singularity"]}
    ### if [ -z "${s_spec}" ]
    ### then
    ###     s_spec=${specs["${REPO}_singularity"]}
    ### fi

    # do not create the docker io
    ### echo "Running IO-Met on: ${cont} docker/${wiring} ${TAG} ${PRODUCT}"
    ### ${DIR}/io-met.py docker/${wiring} ${spec} ${TAG} ${MOZART_REST_URL} ${GRQ_REST_URL}
    ### if (( $? != 0 ))
    ### then
    ###    echo "[ERROR] Failed to create metadata and ingest hysds-io for: ${PRODUCT}" 1>&2
    ###    exit 3
    ### fi

    echo "****** before calling io-met for singularity ******"
    ### echo "s_spec: ${s_spec}"

    ### echo "Running IO-Met on: ${s_spec} docker/${wiring} ${S_TAG} ${PRODUCT}"
    # if called with s_spec, [python3_singularity] option will NOT be in the pull-down list of on-demand
    ### ${DIR}/io-met.py docker/${wiring} ${s_spec} ${S_TAG} ${MOZART_REST_URL} ${GRQ_REST_URL}
    # ${spec} in the io-met call needs to match with ${TAG} in the job-met call in order to find the job
    echo "Running IO-Met on: ${spec} docker/${wiring} ${S_TAG} ${PRODUCT}"
    ${DIR}/io-met.py docker/${wiring} ${spec} ${S_TAG} ${MOZART_REST_URL} ${GRQ_REST_URL}
    if (( $? != 0 ))
    then
        echo "[ERROR] Failed to create metadata and ingest hysds-io for: ${PRODUCT}" 1>&2
        exit 3
    fi

done
exit 0
