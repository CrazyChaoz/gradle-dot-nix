{ pkgs, gradle-verification-metadata-file }:
let
  gradle-fetcher-src = ./.;

  gradle-deps-json = pkgs.stdenv.mkDerivation {
    name = "gradle-deps-json-derivation";
    src = ./.;
    buildInputs = [ pkgs.python3 ];
    buildPhase = ''
      python3 ${gradle-fetcher-src}/gradle-metadata-to-json.py ${gradle-verification-metadata-file} $out
    '';
  };

  gradle-deps-nix = builtins.fromJSON (builtins.readFile gradle-deps-json);

  conversion-function = unique-dependency:
    if unique-dependency.is_added_pom_file == "true" then
      {
        name = unique-dependency.artifact_dir + "/" + unique-dependency.artifact_name;
        path = "${pkgs.writeText unique-dependency.artifact_name ''
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
                           ''}";
      }
    else if unique-dependency.has_module_file == "true" then
      let
        module-derivation = pkgs.stdenv.mkDerivation {
          name = unique-dependency.module_file.artifact_name;
          src = ./.;
          nativeBuildInputs = [ pkgs.python3 pkgs.python3Packages.requests ];
          installPhase = ''
            python3 ${gradle-fetcher-src}/fetch-gradle-dependency.py $out True ${unique-dependency.module_file.name} ${unique-dependency.module_file.group} ${unique-dependency.module_file.version} ${unique-dependency.module_file.artifact_name} ${unique-dependency.module_file.artifact_dir}
          '';
          outputHashAlgo = "sha256";
          outputHash = unique-dependency.module_file.sha_256;
        };
        actual-name = pkgs.stdenv.mkDerivation {
          name = unique-dependency.artifact_name;
          src = ./.;
          nativeBuildInputs = [ pkgs.python3 pkgs.python3Packages.requests ];
          installPhase = ''
            python3 ${gradle-fetcher-src}/rename-module.py ${module-derivation} ${unique-dependency.artifact_name} ${unique-dependency.artifact_dir}  $out
          '';
        };
      in
      {
        name = builtins.readFile actual-name;

        path = "${pkgs.stdenv.mkDerivation {
            name = unique-dependency.artifact_name;
            src = ./.;
            nativeBuildInputs = [ pkgs.python3 pkgs.python3Packages.requests  ];
            installPhase = ''
                python3 ${gradle-fetcher-src}/fetch-gradle-dependency.py $out False ${unique-dependency.name} ${unique-dependency.group} ${unique-dependency.version} ${unique-dependency.artifact_name} ${unique-dependency.artifact_dir} ${unique-dependency.sha_256} ${unique-dependency.module_file.artifact_name}
            '';
            outputHashAlgo = "sha256";
            outputHash = unique-dependency.sha_256;
        }}";
      }
    else
      {
        name = unique-dependency.artifact_dir + "/" + unique-dependency.artifact_name;
        path = "${pkgs.stdenv.mkDerivation {
            name = unique-dependency.artifact_name;
            src = ./.;
            nativeBuildInputs = [ pkgs.python3 pkgs.python3Packages.requests ];
            installPhase = ''
                python3 ${gradle-fetcher-src}/fetch-gradle-dependency.py $out True ${unique-dependency.name} ${unique-dependency.group} ${unique-dependency.version} ${unique-dependency.artifact_name} ${unique-dependency.artifact_dir} ${unique-dependency.sha_256}
            '';
            outputHashAlgo = "sha256";
            outputHash = unique-dependency.sha_256;
        }}";
      }
  ;

  gradle-dependency-maven-repo = pkgs.linkFarm "maven-repo" (map conversion-function gradle-deps-nix.components);

  # idea taken from https://bmcgee.ie/posts/2023/02/nix-what-are-fixed-output-derivations-and-why-use-them/
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
