import os
import re
import subprocess
import requests

TYPE_TAIL_RE = re.compile(".*/([^/]*).json.?(.*)")
REPO_RE = re.compile(".*/([^/ ]+).git")


def get_repo(directory):
    """
    Get the repository for a given directory
    @param directory: directory to check git repo for
    @return: git repo of supplied directory
    """
    sto, ste = subprocess.Popen("cd {}; git remote -v".format(
        directory), shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()
    for line in sto.split("\n"):
        match = REPO_RE.match(line)
        if match:
            return match.group(1)
    raise Exception(f"Failed to determine git repo of: {directory}.{ste}")


def get_product_id(specification, version):
    """
    Get the product id from the specification and version.
    @param specification: specification name to create product id from
    @param version: version to used to create the product
    @return: product id
    """
    match = TYPE_TAIL_RE.match(specification)
    if not match or not match.group(1) in ["job-spec", "hysds-io"]:
        raise Exception("Invalid specification path")
    ptype = "job" if match.group(1) == "job-spec" else "hysds-io"
    name = match.group(2)
    if name == "":
        name = get_repo(os.path.basename(specification))
    return f"{ptype}-{name}:{version}"


def check_exists(item, rest_url):
    """
    Checks the existence of item in ES
    @param item: item to check
    @param rest_url: rest API endpoint
    @return: True if item exists
    """

    ptype = "container"
    if item.startswith("job"):
        ptype = "job_spec"
    elif item.startswith("hysds_io"):
        ptype = "hysds_io"
    url = os.path.join(rest_url, "{}/{}?id={}".format(
        ptype, "info" if item.startswith("container") else "type", item))

    try:
        r = requests.get(url, verify=False)
        r.raise_for_status()
        return True
    except Exception as e:
        print(f"Failed to find {item} because of {type(e)}.{e}")
    return False
