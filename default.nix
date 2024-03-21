{ pkgs, gradle-verification-metadata-file }:
let
  # we need to convert the gradle metadata to json
  # this json data is completely static and can be used to fetch the dependencies
  gradle-deps-json = pkgs.stdenv.mkDerivation {
    name = "gradle-deps-json";
    src = ./.;
    buildInputs = [ pkgs.python3 ];
    buildPhase = ''
      python3 gradle-metadata-to-json.py ${gradle-verification-metadata-file} $out
    '';
  };

  # we need to convert the json data to data that nix understands
  gradle-deps-nix = builtins.fromJSON (builtins.readFile gradle-deps-json);

  # the central conversion function
  # it takes one dependency description (a nix attribute set) and converts it to a nix derivation
  # depending on the type of the dependency, we need to do different things
  #
  # if we set the is_added_pom_file attribute to true, we can just create a file with the pom content
  # this is done, because sometimes there are dependencies which are missing their pom file in the metadata file, but gradle complains if they're missing
  # taken from: https://gist.github.com/tadfisher/17000caf8653019a9a98fd9b9b921d93#file-maven-repo-nix
  #
  # if we set the has_module_file attribute to true, we need to fetch the module file and rename it to the artifact name
  # this is done because sometimes ther is renaming happening in the module file, which is not reflected in the metadata file
  # the file in verification-metadata.xml has a different name than the file on the server
  # so we need to fetch the module file, get the mapping of names and fetch the correct file
  # for the name in the store we need the name from the module information again, so we need the derivation for the module again.
  # this can probably be optimized, but for now it's fine
  #
  # the third case is where we just fetch the file from the server
  # this is only done for .module files, because they are never renamed
  conversion-function = unique-dependency:
    if unique-dependency.is_added_pom_file == "true" then
      let
        actual-file = pkgs.writeText unique-dependency.artifact_name ''
          <project xmlns="http://maven.apache.org/POM/4.0.0"
                   xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
                   http://maven.apache.org/xsd/maven-4.0.0.xsd"
                   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <!-- This module was also published with a richer model, Gradle metadata,  -->
            <!-- which should be used instead. Do not delete the following line which  -->
            <!-- is to indicate to Gradle or any Gradle module metadata file consumer  -->
            <!-- that they should prefer consuming it instead. -->
            <!-- do_not_remove: published-with-gradle-metadata -->
            <modelVersion>4.0.0</modelVersion>
            <groupId>${unique-dependency.group}</groupId>
            <artifactId>${unique-dependency.name}</artifactId>
            <version>${unique-dependency.version}</version>
          </project>
        '';
      in
      pkgs.stdenv.mkDerivation {
        name = unique-dependency.artifact_name;
        src = ./.;
        INTERNAL_PATH = unique-dependency.artifact_dir + "/" + unique-dependency.artifact_name;
        installPhase = ''
          directory=$out/$(dirname "$INTERNAL_PATH")
          mkdir -p $directory
          cp ${actual-file} $out/$INTERNAL_PATH
        '';
      }
    else if unique-dependency.has_module_file == "true" then
      let
        module-derivation = pkgs.stdenv.mkDerivation {
          name = unique-dependency.module_file.artifact_name;
          src = ./.;
          nativeBuildInputs = [ pkgs.python3 pkgs.python3Packages.requests ];
          installPhase = ''
            python3 fetch-gradle-dependency.py $out True ${unique-dependency.module_file.name} ${unique-dependency.module_file.group} ${unique-dependency.module_file.version} ${unique-dependency.module_file.artifact_name} ${unique-dependency.module_file.artifact_dir} ${unique-dependency.module_file.sha_256}
          '';
          outputHashAlgo = "sha256";
          outputHash = unique-dependency.module_file.sha_256;
        };
        actual-file = pkgs.stdenv.mkDerivation {
          name = unique-dependency.artifact_name;
          src = ./.;
          nativeBuildInputs = [ pkgs.python3 pkgs.python3Packages.requests ];
          installPhase = ''
            python3 fetch-gradle-dependency.py $out False ${unique-dependency.name} ${unique-dependency.group} ${unique-dependency.version} ${unique-dependency.artifact_name} ${unique-dependency.artifact_dir} ${unique-dependency.sha_256} ${unique-dependency.module_file.artifact_name}
          '';
          outputHashAlgo = "sha256";
          outputHash = unique-dependency.sha_256;
        };
      in
      pkgs.stdenv.mkDerivation {
        name = unique-dependency.artifact_name;
        src = ./.;
        nativeBuildInputs = [ pkgs.python3 ];
        installPhase = ''
          INTERNAL_PATH=`python3 rename-module.py ${module-derivation} ${unique-dependency.artifact_name} ${unique-dependency.artifact_dir}`
          directory=$out/$(dirname "$INTERNAL_PATH")
          mkdir -p $directory

          cp ${actual-file} $out/$INTERNAL_PATH
        '';
      }
    else
      let
        actual-file = pkgs.stdenv.mkDerivation {
          name = unique-dependency.artifact_name;
          src = ./.;
          nativeBuildInputs = [ pkgs.python3 pkgs.python3Packages.requests ];
          installPhase = ''
            python3 fetch-gradle-dependency.py $out True ${unique-dependency.name} ${unique-dependency.group} ${unique-dependency.version} ${unique-dependency.artifact_name} ${unique-dependency.artifact_dir} ${unique-dependency.sha_256}
          '';
          outputHashAlgo = "sha256";
          outputHash = unique-dependency.sha_256;
        };
      in
      pkgs.stdenv.mkDerivation {
        name = unique-dependency.artifact_name;
        src = ./.;
        INTERNAL_PATH = unique-dependency.artifact_dir + "/" + unique-dependency.artifact_name;
        installPhase = ''
          directory=$out/$(dirname "$INTERNAL_PATH")
          mkdir -p $directory
          cp ${actual-file} $out/$INTERNAL_PATH
        '';
      }
  ;



  # this is where all the dependencies are collected into a single repository
  # the pkgs.linkFarm function takes an array of attribute sets
  # --> each with
  # --> * name: is converted to a path in the output
  # --> * path: the actual path to the derivation
  # the output of this function is a single derivation which contains all the dependencies
  # the input is the array of the nixified dependencies, which are fed into the conversion function
  gradle-dependency-maven-repo = pkgs.symlinkJoin { name= "maven-repo"; paths = (map conversion-function gradle-deps-nix.components); postBuild = "echo maven repo built"; };

  # idea taken from https://bmcgee.ie/posts/2023/02/nix-what-are-fixed-output-derivations-and-why-use-them/
  # gradle has a huge disliking for self fetched dependencies
  # it usually tries to fetch the dependencies itself, which is not what we want
  # we want to use an offline repository, so we need to tell gradle to use our repository
  # there are 3 ways to use offline dependencies in gradle
  # 1. use the cached dependencies from the gradle cache under ~/.gradle/caches/modules-2/files-2.1
  # --> this would be perfect, but gradle does not like to use the cache if its own metadata files are not present, and those are nondeterministic
  # --> could still be valid, since no nondeterminism escapes the sandbox, it probably just stems from some internal cache invalidation strategy
  # 2. we can create a maven repo that we reference in the build configuration
  # --> this was state-of-the-art when dealing with offline dependencies, but it's not the best solution anymore (i think)
  # --> this is what also can be done with ${gradle-dependency-maven-repo}
  # 3. we can use the init.gradle file to tell gradle to use our repository
  # --> this is the best solution, because it's the most flexible and the most explicit
  # --> we can use the init.gradle file to tell gradle to use our repository
  # --> there can even be multiple init.gradle files, so there is not even a need to avoid other init files, we can just add our own
  # --> and this does not / should not require any changes to the build configuration
  # --> it is a transparent change
  #
  # what is happening here?
  # we create a file called init.gradle.kts
  # it changes the project settings (settings.gradle.kts or settings.gradle) to use our repository
  # i'm not sure if we also need repositoriesMode.set(RepositoriesMode.PREFER_PROJECT), but it surely helps

  gradleInit = pkgs.writeText "init.gradle.kts" ''
    settingsEvaluated {
        pluginManagement {
            repositories {
                maven { url = uri("${gradle-dependency-maven-repo}") }
            }
        }
        dependencyResolutionManagement {
            repositoriesMode.set(RepositoriesMode.PREFER_PROJECT)
            repositories {
                maven { url = uri("${gradle-dependency-maven-repo}") }
            }
        }
    }
  '';
in
{
  mvn-repo = gradle-dependency-maven-repo;
  gradle-init = gradleInit;
  gradle-deps-json = gradle-deps-json;
}
