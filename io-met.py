#!/usr/bin/env python
from __future__ import print_function
import sys
import json
import os
import re

import hysds_commons.request_utils
from hysds.celery import app
import utils

def usage_and_exit():
    '''
    Prints usage and exit
    '''
    print("Usage:\n\t{0} <hysds-io> <job-spec> <version>".format(sys.argv[0]),file=sys.stderr)
    sys.exit(-1)

if __name__ == "__main__":
    '''
    Main program routing arguments to file
    '''
    if len(sys.argv) != 4:
        usage_and_exit()
    #Read arguments
    specification = sys.argv[1]
    job_spec = sys.argv[2]
    version=sys.argv[3]
    #Generate product name
    product=utils.get_product_id(specification,version)
    #Prepare dataset metadata
    metadata = {
        "job-specification": job_spec,
        "job-version": version,
        "resource":"hysds-io-specification"
    }
    if not utils.check_exists(job_spec):
        print("[ERROR] Job Specification, {0}, does not exist. Cannot create HySDS-IO.".format(job_spec),file=sys.stderr)
        sys.exit(-2)
    #Read specification metadata and merge it
    with open(specification,"r") as fp:
        metadata.update(json.load(fp))
    metadata["id"] = product
    if metadata.get("component","tosca") == "mozart":
        hysds_commons.request_utils.requests_json_response("POST", os.path.join(app.conf["MOZART_REST_URL"],"hysds_io/add"), data={"spec":json.dumps(metadata)}, verify=False) 
    else:
        hysds_commons.request_utils.requests_json_response("POST", os.path.join(app.conf["GRQ_REST_URL"],"hysds_io/add"), data={"spec":json.dumps(metadata)}, verify=False)
    sys.exit(0)
