{
  description = "Megaparsec Nix helpers";
  inputs = {
    nixpkgs = {
      type = "github";
      owner = "NixOS";
      repo = "nixpkgs";
      ref = "nixpkgs-unstable";
    };
    flake-utils = {
      type = "github";
      owner = "numtide";
      repo = "flake-utils";
    };
  };
  outputs = { self, nixpkgs, flake-utils }:
    let
      pkgs = import nixpkgs {
        system = "x86_64-linux";
        config.allowBroken = true;
      };
      ghc = "ghc924";

      slowMegaparsecSource = pkgs.lib.sourceByRegex ./. [
        "^CHANGELOG\.md$"
        "^LICENSE\.md$"
        "^README\.md$"
        "^Text.*$"
        "^bench.*$"
        "^megaparsec\.cabal$"
      ];

      slowMegaparsecTestsSource = pkgs.lib.sourceByRegex ./megaparsec-tests [
        "^LICENSE\.md$"
        "^README\.md$"
        "^megaparsec-tests\.cabal$"
        "^src.*$"
        "^tests.*$"
      ];

      parsersBenchSource = pkgs.lib.sourceByRegex ./parsers-bench [
        "^README\.md$"
        "^parsers-bench\.cabal$"
        "^ParsersBench.*$"
        "^bench.*$"
        "^data.*$"
      ];

      doBenchmark = p:
        let
          targets = [ "bench-speed" "bench-memory" ];
          copying = pkgs.lib.concatMapStrings
            (t: "cp dist/build/${t}/${t} $out/bench/\n")
            targets;
        in
        pkgs.haskell.lib.doBenchmark
          (p.overrideAttrs (drv: {
            postInstall = ''
              mkdir -p $out/bench
              if test -d data/
              then
                mkdir -p $out/bench/data
                cp data/* $out/bench/data/
              fi
              ${copying}
            '';
          }));

      doJailbreak = pkgs.haskell.lib.doJailbreak;

      patch = p: patch:
        pkgs.haskell.lib.appendPatch p patch;

      slowMegaparsecOverlay = self: super: {
        "slow-megaparsec" = doBenchmark
          (super.callCabal2nix "megaparsec" slowMegaparsecSource { });
        "slow-megaparsec-tests" =
          super.callCabal2nix "megaparsec-tests" slowMegaparsecTestsSource { };
        # The ‘parser-combinators-tests’ package is a bit special because it
        # does not contain an executable nor a library, so its install phase
        # normally fails. We want to build it and run the tests anyway, so we
        # have to do these manipulations.
        "parser-combinators-tests" = pkgs.haskell.lib.dontHaddock
          (super.parser-combinators-tests.overrideAttrs (drv: {
            installPhase = "mkdir $out";
          }));
        "modern-uri" = doBenchmark super.modern-uri;
        "parsers-bench" = doBenchmark
          (super.callCabal2nix "parsers-bench" parsersBenchSource { });
        "mmark" = doBenchmark super.mmark;
      };

      updatedPkgs = pkgs // {
        haskell = pkgs.haskell // {
          packages = pkgs.haskell.packages // {
            "${ghc}" = pkgs.haskell.packages.${ghc}.override {
              overrides = slowMegaparsecOverlay;
            };
          };
        };
      };

      haskellPackages = updatedPkgs.haskell.packages.${ghc};

      # Base: Megaparsec and its unit tests:
      base = {
        inherit (haskellPackages)
          # hspec-megaparsec
          slow-megaparsec
          slow-megaparsec-tests
          parser-combinators-tests;
      };

      # Benchmarks:
      benches = {
        inherit (haskellPackages)
          slow-megaparsec
          mmark
          modern-uri
          parsers-bench;
      };

      # Source distributions:
      dist = with pkgs.haskell.lib; {
        slow-megaparsec = sdistTarball haskellPackages.slow-megaparsec;
        slow-megaparsec-tests = sdistTarball haskellPackages.slow-megaparsec-tests;
      };
      haskellLanguageServer = pkgs.haskell.lib.overrideCabal haskellPackages.haskell-language-server
        (_: { enableSharedExecutables = true; });
    in
    flake-utils.lib.eachDefaultSystem (system:
      {
        packages = flake-utils.lib.flattenTree {
          base = pkgs.recurseIntoAttrs base;
          all_base = pkgs.linkFarmFromDrvs "base" (builtins.attrValues base);
          benches = pkgs.recurseIntoAttrs benches;
          all_benches = pkgs.linkFarmFromDrvs "benches" (builtins.attrValues benches);
          dist = pkgs.recurseIntoAttrs dist;
          all_dist = pkgs.linkFarmFromDrvs "dist" (builtins.attrValues dist);
        };
        defaultPackage = base.slow-megaparsec;
        devShells.default = haskellPackages.shellFor {
          packages = ps: [
            ps.slow-megaparsec
            ps.slow-megaparsec-tests
          ];
          buildInputs = with haskellPackages; [
            cabal-install
            ghcid
            haskellLanguageServer
          ];
        };
      });
}
