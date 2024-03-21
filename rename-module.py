import sys
import json
import os

module_file = sys.argv[1]

with open(module_file, 'r') as json_file:
        module_data = json.load(json_file)
        renaming_aliases = {}
        for variant in module_data.get('variants', []):
            for file in variant.get('files', []):
                renaming_aliases[file['name']] = file['url']

        artifact_name = sys.argv[2]
        if renaming_aliases.get(artifact_name):
            artifact_name = renaming_aliases.get(artifact_name)

        artifact_name = os.path.join(sys.argv[3], artifact_name)

        print(artifact_name)