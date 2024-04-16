import json
import requests
import hashlib
import sys
import os

def download_artifact(_output_file, unprotected_maven_url_file, _name, _group, _version, _artifact_name, _artifact_dir,
                      _sha256hash=None):
    """
    Download the artifact from the Maven2 repository

    :param _output_file: The output file path, is the nix $out variable
    :param unprotected_maven_url_file: The JSON-string list of unprotected Maven2 URLs
    :param _name: The name of the component
    :param _group: The group of the component
    :param _version: The version of the component
    :param _artifact_name: The name of the artifact
    :param _artifact_dir: The directory of the artifact
    :param _sha256hash: The SHA256 hash of the artifact
    :return: None
    """
    print(f"Downloading {_artifact_name} for {_group}:{_name}:{_version} from {_artifact_dir}")

    # Number of attempts
    attempts = 0

    component_identifier = f"{_group.replace('.', '/')}/{_name}/{_version}/{_artifact_name}"

    # Iterate through Maven2 URLs
    with open(unprotected_maven_url_file, 'r') as unprotected_maven_url_file:
        maven_urls = json.load(unprotected_maven_url_file)
        for maven_url in maven_urls:
            # Increment the number of attempts
            attempts += 1

            # Construct the Maven2 URL for the current component
            package_url = f"{maven_url}/{component_identifier}"

            print(f"Attempting to download {_artifact_name} for {_group}:{_name}:{_version} from {package_url}")

            # Download the package
            response = requests.get(package_url, stream=True)

            if response.status_code == 200:

                with open(_output_file, 'wb') as _file:
                    for chunk in response.iter_content(chunk_size=128):
                        _file.write(chunk)
                print(
                    f"\n Downloaded '{_artifact_name}' for {_group}:{_name}:{_version} from {maven_url} to local repository. \n Repo URL: {package_url}")

                with open(_output_file, "rb") as f:
                    # Read and update hash string value in blocks of 4K
                    sha256_hash = hashlib.sha256()
                    for byte_block in iter(lambda: f.read(4096), b""):
                        sha256_hash.update(byte_block)
                    # Check if the computed hash matches the given hash
                    if sha256_hash.hexdigest() == _sha256hash:
                        return

            else:
                print(f"\nFailed to download '{_artifact_name}' for {_group}:{_name}:{_version} from {maven_url}.")
                if attempts == len(maven_urls):
                    print(
                        f"\n\nERROR: Failed to download '{_artifact_name}' for {_group}:{_name}:{_version} from all Maven2 URLs !!!!\n\n")


if sys.argv[2] == "fetch-module":
    download_artifact(sys.argv[1], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7], sys.argv[8], sys.argv[9])
else:
    # resolve the module file first
    os.makedirs("tmp", exist_ok=True)
    download_artifact('tmp/module_file.module', sys.argv[3], sys.argv[4], sys.argv[5],sys.argv[6], sys.argv[10], sys.argv[8])
    # process the component
    with open('tmp/module_file.module', 'r') as json_file:
        module_data = json.load(json_file)
        renaming_aliases = {}
        for variant in module_data.get('variants', []):
            for file in variant.get('files', []):
                renaming_aliases[file['name']] = file['url']

        artifact_name = sys.argv[7]
        if renaming_aliases.get(artifact_name):
            artifact_name = renaming_aliases.get(artifact_name)

        download_artifact(sys.argv[1], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], artifact_name, sys.argv[8], sys.argv[9])
