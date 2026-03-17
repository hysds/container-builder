#!/usr/bin/env python
import sys
import os
import json

import requests
import osaka.main


if __name__ == "__main__":
    if len(sys.argv) < 7:
        print("[ERROR] Metadata requires: ident version product repo digest mozart_url [product_arm64]", file=sys.stderr)
        sys.exit(-1)

    # Read arguments
    ident = sys.argv[1]
    version = sys.argv[2]
    product = sys.argv[3]
    repo = sys.argv[4]
    digest = sys.argv[5]
    mozart_rest_url = sys.argv[6]
    product_arm64 = sys.argv[7] if len(sys.argv) > 7 else None

    # Upload x86_64 tarball (backwards compatible)
    if product:
        url = os.path.join(repo, os.path.basename(product))
        osaka.main.put("./" + product, url)
    else:
        url = ""

    # Upload arm64 tarball
    url_arm64 = ""
    if product_arm64:
        url_arm64 = os.path.join(repo, os.path.basename(product_arm64))
        osaka.main.put("./" + product_arm64, url_arm64)

    # Build metadata with backwards compatibility
    metadata = {
        "name": ident,
        "version": version,
        "url": url,
        "resource": "container",
        "digest": digest
    }
    
    # Add architecture-specific URLs if available
    if url or url_arm64:
        urls_dict = {}
        if url:
            urls_dict["x86_64"] = url
            urls_dict["amd64"] = url
        if url_arm64:
            urls_dict["arm64"] = url_arm64
            urls_dict["aarch64"] = url_arm64
        metadata["urls"] = json.dumps(urls_dict)

    add_container_endpoint = os.path.join(mozart_rest_url, "container/add")
    r = requests.post(add_container_endpoint, data=metadata, verify=False)
    r.raise_for_status()

    sys.exit(0)
