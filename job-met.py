#!/usr/bin/env python
from __future__ import print_function
import sys
import json
import os
import re
import hysds_commons.request_utils
import utils


def usage_and_exit():
    '''
    Prints usage and exit
    '''
    print("Usage:\n\t{0} <job-spec> <container> <version>".format(sys.argv[0]), file=sys.stderr)
    sys.exit(-1)


if __name__ == "__main__":
    if len(sys.argv) != 5:
        usage_and_exit()
    # Read arguments
    specification = sys.argv[1]
    container = sys.argv[2]
    version = sys.argv[3]
    mozart_rest_url = sys.argv[4]
    product = utils.get_product_id(specification, version)
    # Prepare dataset metadata
    metadata = {
        "container": container,
        "job-version": version,
        "resource": "jobspec"
    }
    if not utils.check_exists(container, mozart_rest_url):
        print("[ERROR] Container, {0}, does not exist. Cannot create HySDS-IO.".format(container), file=sys.stderr)
        sys.exit(-2)
    # Read specification metadata and merge it
    with open(specification, "r") as fp:
        metadata.update(json.load(fp))
    metadata["id"] = product
    hysds_commons.request_utils.requests_json_response("POST", os.path.join(
        mozart_rest_url, "job_spec/add"), data={"spec": json.dumps(metadata)}, verify=False)
    sys.exit(0)
