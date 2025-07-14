#!/usr/bin/env python
import sys
import json
import os
import utils
from string import Template
import requests


def usage_and_exit():
    """Prints usage and exit"""
    print(f"Usage:\n\t{sys.argv[0]} <job-spec> <container> <version> <storage>", file=sys.stderr)
    sys.exit(-1)


def resolve_dependency_images(payload, storage):
    """Resolve dependency images located in the cluster's code bucket"""
    if storage.endswith('/'):
        storage = storage[:-1]
    dep_cfgs = payload.get('dependency_images', [])
    for dep_cfg in dep_cfgs:
        if 'container_image_url' in dep_cfg:
            dep_cfg['container_image_url'] = Template(
                dep_cfg['container_image_url']).substitute(CODE_BUCKET_URL=storage)


if __name__ == "__main__":
    if len(sys.argv) != 6:
        usage_and_exit()

    # Read arguments
    specification = sys.argv[1]
    container = sys.argv[2]
    version = sys.argv[3]
    mozart_rest_url = sys.argv[4]
    storage = sys.argv[5]
    product = utils.get_product_id(specification, version)

    # Prepare dataset metadata
    metadata = {
        "container": container,
        "job-version": version,
        "resource": "jobspec"
    }

    if not utils.check_exists(container, mozart_rest_url):
        print("[ERROR] Container, {}, does not exist. Cannot create HySDS-IO.".format(
            container), file=sys.stderr)
        sys.exit(-2)

    # Read specification metadata and merge it
    with open(specification) as fp:
        payload = json.load(fp)
        resolve_dependency_images(payload, storage)
        metadata.update(payload)

    metadata["id"] = product
    endpoint = os.path.join(mozart_rest_url, "job_spec/add")
    r = requests.post(endpoint, data={"spec": json.dumps(metadata)}, verify=False)
    r.raise_for_status()

    sys.exit(0)
