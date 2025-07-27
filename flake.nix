{
  description = "ghc.nix - the ghc devShell";
  nixConfig = {
    bash-prompt = "\\[\\e[34;1m\\]ghc.nix ~ \\[\\e[0m\\]";
    extra-substituters = [ "https://ghc-nix.cachix.org" ];
    extra-trusted-public-keys = [ "ghc-nix.cachix.org-1:ziC/I4BPqeA4VbtOFpFpu6D1t6ymFvRWke/lc2+qjcg=" ];
  };

  inputs = {
    # FUTUREWORK: Use a released version (!= unstable) of nixpkgs again, once GHC 9.10 is
    # fully supported by it.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };

    all-cabal-hashes = {
      url = "github:commercialhaskell/all-cabal-hashes/hackage";
      flake = false;
    };

    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        nixpkgs-stable.follows = "nixpkgs";
        flake-compat.follows = "flake-compat";
      };
    };

    ghc-wasm-meta.url = "gitlab:ghc/ghc-wasm-meta?host=gitlab.haskell.org";
  };

  outputs =
    { self
    , nixpkgs
      # deadnix: skip
    , flake-compat
    , all-cabal-hashes
    , pre-commit-hooks
    , ghc-wasm-meta
    }:
    let
      supportedSystems =
        # allow nix flake show and nix flake check when passing --impure
        if builtins.hasAttr "currentSystem" builtins
        then [ builtins.currentSystem ]
        else nixpkgs.lib.systems.flakeExposed;
      perSystem = nixpkgs.lib.genAttrs supportedSystems;

      lib = { inherit supportedSystems perSystem; };

      defaultSettings = system: {
        inherit nixpkgs system;
        all-cabal-hashes = all-cabal-hashes.outPath;
        inherit (ghc-wasm-meta.outputs.packages."${system}") wasi-sdk wasmtime;
        node-wasm = ghc-wasm-meta.outputs.packages."${system}".nodejs;
      };

      pre-commit-check = system: pre-commit-hooks.lib.${system}.run {
        src = ./.;
        hooks = {
          nixpkgs-fmt.enable = true;
          statix.enable = true;
          deadnix.enable = true;
          typos.enable = true;
        };
      };

      # NOTE: change this according to the settings allowed in the ./ghc.nix file and described
      # in the `README.md`
      userSettings = {
        withHadrianDeps = true;
        withIde = false;
      };
    in
    {
      devShells = perSystem (system: {
        default = self.devShells.${system}.ghc-nix;
        ghc-nix = import ./ghc.nix (defaultSettings system // userSettings);
        wasm-cross = import ./ghc.nix (defaultSettings system // userSettings // { withWasm = true; });
        llvm = import ./ghc.nix (defaultSettings system // userSettings // {
          withLlvm = true;
          # This is optional, but shows how to use Clang to compile C code
          useClang = true;
        });
        # Backward compat synonym
        wasi-cross = self.devShells.${system}.wasm-cross;
        js-cross = import ./ghc.nix (defaultSettings system // userSettings // {
          crossTarget = "javascript-unknown-ghcjs";
          withEMSDK = true;
          withDwarf = false;
        });
        riscv64-linux-cross = import ./ghc.nix (defaultSettings system // userSettings
          // {
          crossTarget = "riscv64-unknown-linux-gnu";
          withQemu = true;
        });
        aarch64-linux-cross = import ./ghc.nix (defaultSettings system // userSettings
          // {
          crossTarget = "aarch64-unknown-linux-gnu";
          withQemu = true;
        });
        ppc64-linux-cross = import ./ghc.nix (defaultSettings system // userSettings
          // {
          crossTarget = "powerpc64-unknown-linux-gnuabielfv2";
          withQemu = true;
        });
        # 32bit Intel
        i686-linux-cross = import ./ghc.nix (defaultSettings system // userSettings
          // {
          crossTarget = "i686-unknown-linux-gnu";
          withQemu = true;
        });

        formatting = nixpkgs.legacyPackages.${system}.mkShell {
          inherit (pre-commit-check system) shellHook;
        };
      });
      formatter = perSystem (system:
        nixpkgs.legacyPackages.${system}.nixpkgs-fmt
      );

      checks = perSystem (system: {
        formatting = pre-commit-check system;
        ghc-nix-shell = self.devShells.${system}.ghc-nix;
      });

      # NOTE: this attribute is used by the flake-compat code to allow passing arguments to ./ghc.nix
      legacy = args: import ./ghc.nix (defaultSettings args.system // args);

      templates.default = {
        path = ./template;
        description = "Quickly apply settings from flakes";
        welcomeText = ''
          Welcome to ghc.nix!
          Set your settings in the `userSettings` attributeset in the `.ghc-nix/flake.nix`.
          Learn more about available arguments at https://gitlab.haskell.org/ghc/ghc.nix/
        '';
      };

      inherit lib;
    };
}
