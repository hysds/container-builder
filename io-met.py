#!/usr/bin/env python

import os
import sys
import json
import re

from hysds_commons.request_utils import requests_json_response
import utils


def add_hysds_io(rest_url, metadata):
    """Index hysds-io into respective components ES preserving allowed_accounts
    if hysds-io already is registered."""

    # get hysds-io if exists
    doc = requests_json_response("GET", os.path.join(rest_url, "hysds_io/type"),
                                 data={"id": metadata['id']}, verify=False,
                                 ignore_errors=True)

    # copy existing allowed accounts
    if doc is not None:
        merged_accounts = list(set(metadata.get('allowed_accounts', []) +
                                   doc['result'].get('allowed_accounts', [])))
        if len(merged_accounts) > 0:
            metadata['allowed_accounts'] = merged_accounts

    # index
    requests_json_response("POST", os.path.join(rest_url, "hysds_io/add"),
                           data={"spec": json.dumps(metadata)}, verify=False)


def usage_and_exit():
    """Prints usage and exit"""

    print("Usage:\n\t{0} <hysds-io> <job-spec> <version> <mozart_rest_url> <grq_rest_url>".format(
        sys.argv[0]), file=sys.stderr)
    sys.exit(-1)


if __name__ == "__main__":
    """Main program routing arguments to file"""

    if len(sys.argv) != 6:
        usage_and_exit()

    # Read arguments
    specification = sys.argv[1]
    job_spec = sys.argv[2]
    version = sys.argv[3]
    mozart_rest_url = sys.argv[4]
    grq_rest_url = sys.argv[5]

    # Generate product name
    product = utils.get_product_id(specification, version)

    # Prepare dataset metadata
    metadata = {
        "job-specification": job_spec,
        "job-version": version,
        "resource": "hysds-io-specification"
    }
    if not utils.check_exists(job_spec, mozart_rest_url):
        print("[ERROR] Job Specification, {0}, does not exist. Cannot create HySDS-IO.".format(
            job_spec), file=sys.stderr)
        sys.exit(-2)

    # Read specification metadata and merge it
    with open(specification, "r") as fp:
        metadata.update(json.load(fp))
    metadata["id"] = product
    if metadata.get("component", "tosca") in ("mozart", "figaro"):
        add_hysds_io(mozart_rest_url, metadata)
    else:
        add_hysds_io(grq_rest_url, metadata)
    sys.exit(0)
