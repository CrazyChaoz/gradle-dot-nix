# parse-verification-metadata.nix
#
# Pure-Nix replacement for gradle-metadata-to-json.py.
# Reads gradle/verification-metadata.xml directly at evaluation time,
# eliminating the IFD caused by shelling out to Python to produce JSON.
#
# Usage (in default.nix):
#   gradle-deps-nix = import ./parse-verification-metadata.nix { inherit (pkgs) lib; }
#                       gradle-verification-metadata-file;
#
# Returns a list of attribute sets with the same shape that conversion-function expects.

{ lib }:

gradle-verification-metadata-file:

let
  rawXml = builtins.readFile gradle-verification-metadata-file;

  # ── Normalise whitespace ────────────────────────────────────────────────────
  # Collapse newlines/tabs to spaces so that `.*` in POSIX ERE regexes can span
  # what were originally multiple lines.  Nix's builtins.match / builtins.split
  # use POSIX ERE where `.` does NOT match `\n`, so this step is essential.
  xml = builtins.replaceStrings [ "\n" "\r" "\t" ] [ " " " " " " ] rawXml;

  # ── Helpers ─────────────────────────────────────────────────────────────────

  isStr = x: !builtins.isList x;

  # Extract an XML attribute value from a *tag-attribute string*.
  # E.g.: getAttr "name" 'group="com.example" name="foo" version="1.0"'  =>  "foo"
  # Works because each attribute appears at most once in a single tag.
  getAttr = attrName: s:
    let m = builtins.match (".*" + attrName + "=\"([^\"]*)\".*") s;
    in if m == null then null else builtins.head m;

  # Rejoin the tail of a builtins.split result (which alternates strings and []
  # match-group lists) back into a single string using `sep` as the delimiter.
  # Used to reconstruct the part of a string that came after the first match.
  rejoinTail = sep: splitResult:
    builtins.concatStringsSep sep
      (builtins.filter isStr (builtins.tail (builtins.tail splitResult)));

  # ── Top-level split on <component ──────────────────────────────────────────
  # builtins.split "<component " xml  =>  [preamble, [], chunk1, [], chunk2, …]
  # We discard the preamble and the [] separators to get one string per component.
  componentChunks =
    builtins.filter isStr (builtins.tail (builtins.split "<component " xml));

  # ── Parse one component chunk ───────────────────────────────────────────────
  # Each chunk starts right after "<component " and contains:
  #   group="…" name="…" version="…"> <artifact …>…</artifact> … </component> …
  parseComponent = chunk:
    let
      # 1. Trim everything from </component> onward (avoids cross-component bleed).
      upToEnd = builtins.head (builtins.split "</component>" chunk);

      # 2. Split on the first ">" to separate the opening-tag attributes from the body.
      splitGt    = builtins.split ">" upToEnd;
      tagAttrs   = builtins.head splitGt;           # 'group="…" name="…" version="…"'
      body       = rejoinTail ">" splitGt;          # ' <artifact …>…</artifact> …'

      # 3. Extract component-level attributes.
      group   = getAttr "group"   tagAttrs;
      name    = getAttr "name"    tagAttrs;
      version = getAttr "version" tagAttrs;

      # Maven layout: com.example.foo  =>  com/example/foo/<name>/<version>
      artifact_dir =
        lib.replaceStrings [ "." ] [ "/" ] group + "/" + name + "/" + version;

      # 4. Split on <artifact  to get one chunk per artifact declaration.
      artifactChunks =
        builtins.filter isStr (builtins.tail (builtins.split "<artifact " body));

      # ── Parse one artifact chunk ────────────────────────────────────────────
      parseArtifact = artChunk:
        let
          upToArtEnd  = builtins.head (builtins.split "</artifact>" artChunk);
          splitArtGt  = builtins.split ">" upToArtEnd;
          artTagAttrs = builtins.head splitArtGt;   # 'name="foo-1.0.jar"'
          artBody     = rejoinTail ">" splitArtGt;  # ' <sha256 value="…" …/> …'

          artifact_name = getAttr "name" artTagAttrs;

          # <sha256 value="…" origin="…"/>
          sha256Parts  = builtins.split "<sha256 " artBody;
          sha256TagStr =
            if builtins.length sha256Parts > 1
            then builtins.elemAt sha256Parts 2   # text starting at the sha256 attributes
            else "";
          sha256Raw = getAttr "value" sha256TagStr;
          sha256    = if sha256Raw == null then "0" else sha256Raw;
        in
        {
          inherit artifact_name sha256;
          isModule = lib.hasSuffix ".module" artifact_name;
        };

      artifacts = map parseArtifact artifactChunks;

      # 5. Partition into .module vs everything else.
      moduleArts  = builtins.filter (a:  a.isModule) artifacts;
      regularArts = builtins.filter (a: !a.isModule) artifacts;

      hasModuleFile = moduleArts != [];
      moduleArt     = if hasModuleFile then builtins.head moduleArts else null;

      # 6. When a .module file exists Gradle also needs a matching .pom.
      #    If the metadata doesn't list it explicitly, we synthesise one.
      syntheticPomName =
        if hasModuleFile
        then lib.removeSuffix ".module" moduleArt.artifact_name + ".pom"
        else null;
      syntheticPomNeeded =
        hasModuleFile
        && !(builtins.any (a: a.artifact_name == syntheticPomName) regularArts);

      # 7. The module_file sub-record referenced by non-module entries.
      moduleFileRecord = {
        inherit name group version artifact_dir;
        artifact_name = moduleArt.artifact_name;
        sha_256       = moduleArt.sha256;
      };

      # 8. Build an output record for one artifact entry.
      #    Field names match what conversion-function in default.nix accesses.
      mkEntry = artifact_name: sha_256: has_module_file: is_added_pom_file:
        {
          inherit name group version artifact_dir;
          inherit artifact_name sha_256 has_module_file is_added_pom_file;
        }
        // lib.optionalAttrs has_module_file { module_file = moduleFileRecord; };

      # The .module file itself (has_module_file = false — it doesn't self-reference).
      moduleEntry =
        lib.optional hasModuleFile
          (mkEntry moduleArt.artifact_name moduleArt.sha256 false false);

      # Regular artifacts (jar, aar, explicitly listed poms, …).
      regularEntries =
        map (a: mkEntry a.artifact_name a.sha256 hasModuleFile false) regularArts;

      # Synthetic pom (is_added_pom_file = true, sha_256 = "0").
      syntheticPomEntry =
        lib.optional syntheticPomNeeded
          (mkEntry syntheticPomName "0" hasModuleFile true);

    in
    moduleEntry ++ regularEntries ++ syntheticPomEntry;

in
lib.concatMap parseComponent componentChunks
