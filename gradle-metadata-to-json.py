import json
import os
import sys
from xml.etree import ElementTree

# Define the namespaces
namespaces = {
    'default': 'https://schema.gradle.org/dependency-verification'
}

def process_component(component):
    group = component.attrib['group']
    name = component.attrib['name']
    version = component.attrib['version']

    # Construct the subdirectory structure in the local repository
    artifact_dir = os.path.join(group.replace('.', '/'), name, version)

    # skipped files
    skipped_files = []

    pom_files = []

    hash_for_artifact = {}

    # module file
    module_file = ""

    # Iterate through the artifacts
    for artifact in component.findall('.//default:artifact', namespaces):
        artifact_name = artifact.attrib['name']
        sha256_element = artifact.find('.//default:sha256', namespaces)
        artifact_hash = sha256_element.attrib['value']

        # Collect all hashes including also-trust
        all_hashes = [artifact_hash]
        for also_trust in sha256_element.findall('.//default:also-trust', namespaces):
            all_hashes.append(also_trust.attrib['value'])

        if not artifact_name.endswith('.module'):
            skipped_files.append(artifact_name)
            hash_for_artifact[artifact_name] = all_hashes
        else:
            module_file = '''
                    {
                        "name" : "''' + name + '''",
                        "group" : "''' + group + '''",
                        "version" : "''' + version + '''",
                        "artifact_name" : "''' + artifact_name + '''",
                        "artifact_dir" : "''' + artifact_dir + '''",
                        "has_module_file" : "false",
                        "is_added_pom_file" : "false",
                        "sha_256" : ''' + json.dumps(all_hashes) + '''
                    }
            '''

            # desperation: add a definite .pom to the list of skipped files
            pom_files.append(artifact_name.replace('.module', '.pom'))
            skipped_files.append(artifact_name.replace('.module', '.pom'))

    output_file.write(module_file)

    if len(skipped_files) > 0 and module_file != "":
        output_file.write(",")

    #iterate through the skipped files using numbered index
    for i, artifact in enumerate(set(skipped_files)):
        if hash_for_artifact.get(artifact) is not None:
            sha_256 = hash_for_artifact.get(artifact)
        else:
            sha_256 = ["0"]

        if module_file != "":
            has_module_file = "true"
        else:
            has_module_file = "false"

        if pom_files.__contains__(artifact) and sha_256 == "0":
            is_added_pom_file = "true"
        else:
            is_added_pom_file = "false"

        if module_file != "":
            text_for_module_file = ''',
                        "module_file" : ''' + module_file
        else:
            text_for_module_file = ""

        output_file.write('''
                    {
                        "name" : "''' + name + '''",
                        "group" : "''' + group + '''",
                        "version" : "''' + version + '''",
                        "artifact_name" : "''' + artifact + '''",
                        "artifact_dir" : "''' + artifact_dir + '''",
                        "sha_256" : ''' + json.dumps(sha_256) + ''',
                        "has_module_file" : "''' + has_module_file + '''",
                        "is_added_pom_file" : "''' + is_added_pom_file + '''"'''+ text_for_module_file + '''
                    }
        ''')

        if i < len(set(skipped_files)) - 1:
            output_file.write(",")


# write the header to the output file
output_file = open(sys.argv[2], 'w')
output_file.write('''
{
    "components" : [
''')

# Iterate through the components using numbered index
components = ElementTree.parse(sys.argv[1]).getroot().findall('.//default:component', namespaces)
for i, _component in enumerate(components):
    process_component(_component)

    if i < len(components) - 1:
        output_file.write(",")

output_file.write("]}")
