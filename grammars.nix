{
  stdenv,
  lib,
  runCommand,
  fetchgit,
  removeReferencesTo,
  includeGrammarIf ? _: true,
  grammarOverlays ? [],
  ...
}: let
  languagesConfig =
    builtins.fromTOML (builtins.readFile ./languages.toml);
  # Pinned git sources. Entries are keyed by grammar name:
  #   { "<name>": { url, rev, hash } }
  # Regenerate with: nix run nixpkgs#python3 -- ./update-grammars.py
  # Using fetchgit (fixed-output) instead of builtins.fetchTree keeps
  # evaluation pure: sources live in /nix/store and are substitutable
  # from binary caches, so downstream builds need no git access.
  lock = builtins.fromJSON (builtins.readFile ./grammars.lock.json);
  isGitGrammar = grammar:
    builtins.hasAttr "source" grammar
    && builtins.hasAttr "git" grammar.source
    && builtins.hasAttr "rev" grammar.source;
  isGitHubGrammar = grammar: lib.hasPrefix "https://github.com" grammar.source.git;
  toGitHubFetcher = url: let
    match = builtins.match "https://github\\.com/([^/]*)/([^/]*)/?" url;
  in {
    owner = builtins.elemAt match 0;
    repo = builtins.elemAt match 1;
  };
  # If `use-grammars.only` is set, use only those grammars.
  # If `use-grammars.except` is set, use all other grammars.
  # Otherwise use all grammars.
  useGrammar = grammar:
    if languagesConfig ? use-grammars.only
    then builtins.elem grammar.name languagesConfig.use-grammars.only
    else if languagesConfig ? use-grammars.except
    then !(builtins.elem grammar.name languagesConfig.use-grammars.except)
    else true;
  grammarsToUse = builtins.filter useGrammar languagesConfig.grammar;
  gitGrammars = builtins.filter isGitGrammar grammarsToUse;
  buildGrammar = grammar: let
    locked = lock.grammars.${grammar.name} or null;
    pinned =
      locked != null
      && locked.url == grammar.source.git
      && locked.rev == grammar.source.rev;
    # Fixed-output source: pure evaluation, cached in store/substituters.
    # fetchSubmodules = false matches the old fetchTree(shallow) behavior:
    # some grammars (e.g. blade) register submodules over SSH that the
    # sandbox cannot clone and that the build does not need.
    pinnedSrc = fetchgit {
      url = locked.url;
      rev = locked.rev;
      hash = locked.hash;
      fetchSubmodules = false;
    };
    # Transitional fallback while the lock is being filled in.
    # Still impure (hits the network at eval time); disappears once
    # every grammar is pinned.
    treeSrc = let
      gh = toGitHubFetcher grammar.source.git;
      sourceGit = builtins.fetchTree {
        type = "git";
        url = grammar.source.git;
        rev = grammar.source.rev;
        ref = grammar.source.ref or "HEAD";
        shallow = true;
      };
      sourceGitHub = builtins.fetchTree {
        type = "github";
        owner = gh.owner;
        repo = gh.repo;
        inherit (grammar.source) rev;
      };
    in
      if isGitHubGrammar grammar
      then sourceGitHub
      else sourceGit;
    source =
      if pinned
      then pinnedSrc
      else if locked == null
      then
        builtins.trace
        "warning: grammar '${grammar.name}' not pinned in grammars.lock.json, using fetchTree (run ./update-grammars.py)"
        treeSrc
      else throw "grammar '${grammar.name}' outdated in grammars.lock.json (languages.toml changed?) - run ./update-grammars.py";
  in
    stdenv.mkDerivation {
      # see https://github.com/NixOS/nixpkgs/blob/fbdd1a7c0bc29af5325e0d7dd70e804a972eb465/pkgs/development/tools/parsing/tree-sitter/grammar.nix

      pname = "helix-tree-sitter-${grammar.name}";
      version = grammar.source.rev;

      src = source;
      # stdenv unpacks a directory source to `<stripHash $src>/`:
      # fetchTree checkouts are always named `source`, fetchgit
      # checkouts are named `<repo>-<shortrev>` (= the derivation name).
      sourceRoot = let
        base =
          if lib.isDerivation source
          then source.name
          else "source";
      in
        if builtins.hasAttr "subpath" grammar.source
        then "${base}/${grammar.source.subpath}"
        else base;

      dontConfigure = true;

      FLAGS = [
        "-Isrc"
        "-g"
        "-O3"
        "-fPIC"
        "-fno-exceptions"
        "-Wl,-z,relro,-z,now"
      ];

      SHARED_LIB = grammar.name + stdenv.hostPlatform.extensions.sharedLibrary;

      buildPhase = ''
        runHook preBuild

        if [[ -e src/scanner.cc ]]; then
          $CXX -c src/scanner.cc -o scanner.o $FLAGS
        elif [[ -e src/scanner.c ]]; then
          $CC -c src/scanner.c -o scanner.o $FLAGS
        fi

        $CC -c src/parser.c -o parser.o $FLAGS
        $CXX -shared -o $SHARED_LIB *.o

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir $out
        mv $SHARED_LIB $out/
        runHook postInstall
      '';

      # Strip failed on darwin: strip: error: symbols referenced by indirect symbol table entries that can't be stripped
      fixupPhase = lib.optionalString stdenv.hostPlatform.isLinux ''
        runHook preFixup
        $STRIP $out/$SHARED_LIB
        runHook postFixup
      '';
    };
  grammarsToBuild = builtins.filter includeGrammarIf gitGrammars;
  builtGrammars =
    builtins.map (grammar: {
      inherit (grammar) name;
      value = buildGrammar grammar;
    })
    grammarsToBuild;
  extensibleGrammars =
    lib.makeExtensible (self: builtins.listToAttrs builtGrammars);
  overlaidGrammars =
    lib.pipe extensibleGrammars
    (builtins.map (overlay: grammar: grammar.extend overlay) grammarOverlays);
  sharedLibExtension = stdenv.hostPlatform.extensions.sharedLibrary;
  # Copy (not symlink) the built libraries into a single output, like
  # nixpkgs' grammarsFarm. Symlinks would keep all ~300 per-grammar
  # derivations in the runtime closure (300+ round trips on cold fetch);
  # copies drop them out once built, leaving a closure of a few paths.
  grammarsToScrub =
    lib.filterAttrs (n: v: lib.isDerivation v) overlaidGrammars;
  grammarCopies =
    lib.mapAttrsToList
    (name: artifact: "cp ${artifact}/${name}${sharedLibExtension} $out/${name}${sharedLibExtension}")
    grammarsToScrub;
  # The -g flag embeds the per-grammar build dir in the .so files; scrub it
  # so the intermediate derivations drop out of the runtime closure.
  grammarScrubs =
    lib.mapAttrsToList
    (name: artifact: "remove-references-to -t ${artifact} $out/${name}${sharedLibExtension}")
    grammarsToScrub;
in
  runCommand "consolidated-helix-grammars" {nativeBuildInputs = [removeReferencesTo];} ''
    mkdir -p $out
    ${builtins.concatStringsSep "\n" grammarCopies}
    ${builtins.concatStringsSep "\n" grammarScrubs}
  ''
