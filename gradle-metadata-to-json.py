import os
import xml.etree.ElementTree as ET
import sys

# Parse the XML file
tree = ET.parse(sys.argv[1])
root = tree.getroot()

# Define the namespaces
namespaces = {
    'default': 'https://schema.gradle.org/dependency-verification'
}

# List of Maven2 URLs to query
maven_urls = [
    "https://dl.google.com/dl/android/maven2",
    "https://repo.maven.apache.org/maven2",
    "https://plugins.gradle.org/m2",
    "https://maven.google.com"
]

# List of failed Packages
failed_packages = []

num_components = len(root.findall('.//default:component', namespaces))

def process_component(component):
    global downloaded_components
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
    # Download the artifact if it is a module file
    for artifact in component.findall('.//default:artifact', namespaces):
        artifact_name = artifact.attrib['name']

        if not artifact_name.endswith('.module'):
            skipped_files.append(artifact_name)
            hash_for_artifact[artifact_name] = artifact.find('.//default:sha256', namespaces).attrib['value']
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
                        "sha_256" : "''' + artifact.find('.//default:sha256', namespaces).attrib['value'] + '''"
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
            sha_256 = "0"

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
                        "sha_256" : "''' + sha_256 + '''",
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
components = root.findall('.//default:component', namespaces)
for i, _component in enumerate(components):
    process_component(_component)

    if i < len(components) - 1:
        output_file.write(",")

output_file.write("]}")
