#!/usr/bin/env python
import sys
import os

import requests
import osaka.main


if __name__ == "__main__":
    if len(sys.argv) != 7:
        print("[ERROR] Metadata dataset.json generation requires a version, and archive file", sys.stderr)
        sys.exit(-1)

    # Read arguments
    ident = sys.argv[1]
    version = sys.argv[2]
    product = sys.argv[3]
    repo = sys.argv[4]
    digest = sys.argv[5]
    mozart_rest_url = sys.argv[6]

    url = os.path.join(repo, os.path.basename(product))

    # OSAKA call goes here
    osaka.main.put("./" + product, url)

    metadata = {
        "name": ident,
        "version": version,
        "url": url,
        "resource": "container",
        "digest": digest
    }

    add_container_endpoint = os.path.join(mozart_rest_url, "container/add")
    requests.post(add_container_endpoint, data=metadata, verify=False)

    sys.exit(0)
