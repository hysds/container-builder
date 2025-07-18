#!/usr/bin/env python
import os
import sys
import json
import requests
import utils


def add_hysds_io(rest_url, data):
    """
    Index hysds-io into respective components ES preserving allowed_accounts
    if hysds-io already is registered.
    """
    _id = data['id']
    hysds_io_obj = {"id": _id}
    hysds_io_endpoint = os.path.join(rest_url, "hysds_io/type")

    # check if HySDS IO if exists
    doc = None
    req = requests.get(hysds_io_endpoint, data=hysds_io_obj, verify=False)
    try:
        req.raise_for_status()
        doc = req.json()
    except requests.exceptions.HTTPError as e:
        if req.status_code == 404:
            print("WARNING: hysds_io not found: %s, cannot merge allowed_accounts" % _id)
        else:
            raise requests.exceptions.HTTPError(e)
    except Exception as e:
        raise Exception(e)

    # copy existing allowed accounts
    if doc is not None:
        merged_accounts = list(set(data.get('allowed_accounts', []) + doc['result'].get('allowed_accounts', [])))
        if len(merged_accounts) > 0:
            data['allowed_accounts'] = merged_accounts

    data = {
        "spec": json.dumps(data)
    }
    r = requests.post(os.path.join(rest_url, "hysds_io/add"), data=data, verify=False)
    r.raise_for_status()


def usage_and_exit():
    """Prints usage and exit"""
    print(f"Usage: {sys.argv[0]}", file=sys.stderr)
    print("Arguments must be supplied: (hysds-io, job-spec, version, mozart_rest_url, grq_rest_ur)", file=sys.stderr)
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
        print(f"ERROR: Job Specification {job_spec} does not exist. Cannot create HySDS-IO.", file=sys.stderr)
        sys.exit(-2)

    # Read specification metadata and merge it
    with open(specification) as fp:
        metadata.update(json.load(fp))

    metadata["id"] = product

    if metadata.get("component", "tosca") in ("mozart", "figaro"):
        add_hysds_io(mozart_rest_url, metadata)
    else:
        add_hysds_io(grq_rest_url, metadata)

    sys.exit(0)
