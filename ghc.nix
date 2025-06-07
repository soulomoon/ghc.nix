# Usage examples:
#
#   nix-shell path/to/ghc.nix/ --pure --run './boot && ./configure && make -j4'
#   nix-shell path/to/ghc.nix/        --run 'hadrian/build -c -j4 --flavour=quickest'
#   nix-shell path/to/ghc.nix/        --run 'THREADS=4 ./validate --slow'
#
let
  pkgsFor = nixpkgs: system: nixpkgs.legacyPackages.${system};
  hadrianPath =
    if builtins.hasAttr "getEnv" builtins
    then "${builtins.getEnv "PWD"}/hadrian/hadrian.cabal"
    else null;
in
args@{ system ? builtins.currentSystem
, nixpkgs
, all-cabal-hashes
  # GHC sources are supposed to be buildable a) with the latest major GHC release,
  # b) with the penultimate major GHC release, c) with GHC built from exactly the
  # same sources.
  # (https://gitlab.haskell.org/ghc/ghc/-/wikis/building/preparation/tools)
, bootghc ? "ghc910"
, version ? "9.13"
, hadrianCabal ? hadrianPath
, useClang ? false  # use Clang for C compilation
, withLlvm ? false
, withDocs ? true
, withGhcid ? false
, withIde ? false
, withHadrianDeps ? false
, withDwarf ? (pkgsFor nixpkgs system).stdenv.isLinux  # enable libdw unwinding support
, withGdb ? let
    pkgs = pkgsFor nixpkgs system;
    # `gdb` should not be included if it is broken.
  in
  (!pkgs.gdb.meta.broken or false)
  # `gdb` should only be included if it is available on the current platform.
  && pkgs.lib.meta.availableOn system pkgs.gdb
, withNuma ? (pkgsFor nixpkgs system).stdenv.isLinux
, withDtrace ? (pkgsFor nixpkgs system).stdenv.isLinux
, withGrind ? !((pkgsFor nixpkgs system).valgrind.meta.broken or false)
, withPerf ? (pkgsFor nixpkgs system).stdenv.isLinux
, withSystemLibffi ? false
, withEMSDK ? false                    # load emscripten for js-backend
, withWasm ? false                     # load the toolchain for wasm backend
, withWasiSDK ? false                  # Backward compat synonym for withWasm.
, withFindNoteDef ? true              # install a shell script `find_note_def`;
  # `find_note_def "Adding a language extension"`
  # will point to the definition of the Note "Adding a language extension"
, wasi-sdk
, wasmtime
, node-wasm
, crossTarget ? null
, withQemu ? false
}:

# Assert that args has only one of withWasm and withWasiSDK.
let
  wasi = args ? withWasiSDK;
  wasm = args ? withWasm;
in
assert (wasi -> !wasm) && (wasm -> !wasi);
let
  # Fold in the backward-compat synonym.
  withWasm' = withWasm || withWasiSDK;
  overlay = self: super: {
    nodejs = super.nodejs_22;
    haskell = super.haskell // {
      packages = super.haskell.packages // {
        ${bootghc} = super.haskell.packages.${bootghc}.override (old: {
          inherit all-cabal-hashes;
          overrides =
            self.lib.composeExtensions
              (old.overrides or (_: _: { }))
              (_hself: hsuper: {
                ormolu =
                  if self.system == "aarch64-darwin"
                  then
                    self.haskell.lib.overrideCabal
                      hsuper.ormolu
                      (_: { enableSeparateBinOutput = false; })
                  else
                    hsuper.ormolu;
              });
        });
      };
    };
  };

  pkgs = import nixpkgs { inherit system; overlays = [ overlay ]; };
  inherit (pkgs) lib;

  # Try to find pkgsCross for the cross target.
  crossPkgs' = builtins.foldl'
    (acc: elem:
      if acc != null then
        acc
      # pkgsCross.ghcjs provides no C compiler, so we fallback to the host's stdenv.
      else if elem.targetPlatform.config == crossTarget
        && !elem.targetPlatform.isGhcjs then
        builtins.trace "Found ${crossTarget} in pkgsCross." elem
      else
        null)
    null
    (builtins.attrValues pkgs.pkgsCross);

  crossPkgs = if crossTarget == null || crossPkgs' == null then pkgs else crossPkgs';

  llvmForGhc = pkgs.llvm_13;

  stdenv =
    if useClang
    then crossPkgs.clangStdenv
    else crossPkgs.stdenv;
  #noTest = haskell.lib.dontCheck;

  hspkgs = pkgs.haskell.packages.${bootghc};

  ourtexlive =
    pkgs.texlive.combine {
      inherit (pkgs.texlive)
        scheme-medium collection-xetex fncychap titlesec tabulary varwidth
        framed capt-of wrapfig needspace dejavu-otf helvetic upquote;
    };
  fonts = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
  docsPackages = if withDocs then [ pkgs.python3Packages.sphinx ourtexlive ] else [ ];

  depsSystem = [
    pkgs.autoconf
    pkgs.automake
    pkgs.m4
    pkgs.less
    pkgs.glibcLocales
    pkgs.perl
    pkgs.git
    pkgs.file
    pkgs.which
    pkgs.python3
    pkgs.xorg.lndir # for source distribution generation
    crossPkgs.zlib.out
    crossPkgs.zlib.dev
    pkgs.hlint
  ]
  ++ docsPackages
  ++ lib.optional withLlvm llvmForGhc
  ++ lib.optional withGrind pkgs.valgrind
  ++ lib.optional withPerf pkgs.linuxPackages.perf
  ++ lib.optionals withEMSDK [ pkgs.emscripten pkgs.nodejs ]
  ++ lib.optionals withWasm' [ wasi-sdk wasmtime node-wasm ]
  ++ lib.optional withNuma pkgs.numactl
  ++ lib.optional withDwarf pkgs.elfutils
  ++ lib.optional withGdb pkgs.gdb
  ++ lib.optional withGhcid pkgs.ghcid
  ++ lib.optional withIde pkgs.haskell.packages.${bootghc}.haskell-language-server
  ++ lib.optional withIde pkgs.clang-tools # N.B. clang-tools for clangd
  ++ lib.optional withDtrace pkgs.linuxPackages.systemtap
  ++ lib.optional withQemu pkgs.qemu
  ++ (if (!stdenv.isDarwin) then
    [ pkgs.pxz ]
  else [
    pkgs.libiconv
    pkgs.darwin.libobjc
    pkgs.darwin.apple_sdk.frameworks.Foundation
  ]);

  # happy =
  # if lib.versionAtLeast version "9.1"
  # then noTest (hspkgs.callHackage "happy" "1.20.1.1" { })
  # else noTest (haskell.packages.ghc865Binary.callHackage "happy" "1.19.12" { });

  # alex =
  # if lib.versionAtLeast version "9.1"
  # then noTest (hspkgs.callHackage "alex" "3.2.7.4" { })
  # else noTest (hspkgs.callHackage "alex" "3.2.7" { });

  # Convenient tools
  configureGhc = pkgs.writeShellScriptBin "configure_ghc" "$CONFIGURE $CONFIGURE_ARGS $@";
  validateGhc = pkgs.writeShellScriptBin "validate_ghc" "config_args='$CONFIGURE_ARGS' ./validate $@";

  depsTools = [
    hspkgs.happy
    hspkgs.alex
    pkgs.cabal-install
    configureGhc
    validateGhc
  ]
  ++ lib.optional withFindNoteDef findNoteDef
  ;

  hadrianCabalExists = !(builtins.isNull hadrianCabal) && builtins.pathExists hadrianCabal;
  hsdrv =
    if (withHadrianDeps &&
      builtins.trace "checking if ${toString hadrianCabal} is present:  ${if hadrianCabalExists then "yes" else "no"}"
        hadrianCabalExists)
    then
      hspkgs.callCabal2nix "hadrian" hadrianCabal
        (
          let
            guessedGhcSrcDir = dirOf (dirOf hadrianCabal);
            ghc-platform = hspkgs.callCabal2nix "ghc-platform" (/. + guessedGhcSrcDir + "/libraries/ghc-platform") { };
            ghc-toolchain = hspkgs.callCabal2nix "ghc-toolchain" (/. + guessedGhcSrcDir + "/utils/ghc-toolchain") { inherit ghc-platform; };
          in
          {
            inherit ghc-platform ghc-toolchain;
          }
        )
    else
      (hspkgs.mkDerivation {
        inherit version;
        pname = "ghc-buildenv";
        license = "BSD";
        src = builtins.filterSource (_: _: false) ./.;

        libraryHaskellDepends = lib.optionals withHadrianDeps [
          hspkgs.extra
          hspkgs.QuickCheck
          hspkgs.shake
          hspkgs.unordered-containers
          hspkgs.cryptohash-sha256
          hspkgs.base16-bytestring
        ];
        librarySystemDepends = depsSystem;
      });

  # These days we have hls-notes-plugin, part of HLS-2.8.0.0.
  # Might as well remove this in the future (says the author of this script),
  # but I haven't tested HLS-2.8 yet.
  findNoteDef = pkgs.writeShellScriptBin "find_note_def" ''
    ret=$(${pkgs.ripgrep}/bin/rg  --no-messages --vimgrep -i --engine pcre2 "^ ?[{\\-#*]* *\QNote [$1]\E\s*$")
    n_defs=$(echo "$ret" | sed '/^$/d' | wc -l)
    while IFS= read -r line; do
      if [[ $line =~ ^([^:]+) ]] ; then
        file=''${BASH_REMATCH[1]}
        if [[ $line =~ hs:([0-9]+): ]] ; then
          pos=''${BASH_REMATCH[1]}
          if cat $file | head -n $(($pos+1)) | tail -n 1 | grep --quiet "~~~" ; then
            echo $file:$pos
          fi
        fi
      fi
    done <<< "$ret"
    if [[ $n_defs -ne 1 ]]; then
      exit 42
    fi
    exit 0
  '';

  CONFIGURE_ARGS = [
    "--with-gmp-includes=${crossPkgs.gmp.dev}/include"
    "--with-gmp-libraries=${crossPkgs.gmp}/lib"
    "--with-curses-includes=${crossPkgs.ncurses.dev}/include"
    "--with-curses-libraries=${crossPkgs.ncurses.out}/lib"
  ] ++ lib.optionals withNuma [
    "--with-libnuma-includes=${crossPkgs.numactl}/include"
    "--with-libnuma-libraries=${crossPkgs.numactl}/lib"
  ] ++ lib.optionals withDwarf [
    "--with-libdw-includes=${crossPkgs.elfutils.dev}/include"
    "--with-libdw-libraries=${crossPkgs.elfutils.out}/lib"
    "--enable-dwarf-unwind"
  ] ++ lib.optionals withSystemLibffi [
    "--with-system-libffi"
    "--with-ffi-includes=${crossPkgs.libffi.dev}/include"
    "--with-ffi-libraries=${crossPkgs.libffi.out}/lib"
  ] ++ lib.optionals (crossTarget != null) [
    "--target=${crossTarget}"
  ];
in
hspkgs.shellFor {
  packages = _pkgset: [ hsdrv ];
  nativeBuildInputs = depsTools;
  buildInputs = depsSystem;
  passthru.pkgs = pkgs;

  hardeningDisable = [ "fortify" ]; ## Effectuated by cc-wrapper
  # Without this, we see a whole bunch of warnings about LANG, LC_ALL and locales in general.
  # In particular, this makes many tests fail because those warnings show up in test outputs too...
  # The solution is from: https://github.com/NixOS/nix/issues/318#issuecomment-52986702
  LOCALE_ARCHIVE = if stdenv.isLinux then "${pkgs.glibcLocales}/lib/locale/locale-archive" else "";
  inherit CONFIGURE_ARGS;

  shellHook = ''
    # somehow, CC gets overridden so we set it again here.
    export CC=${stdenv.cc}/bin/${stdenv.cc.targetPrefix}cc
    # This prevents `./configure` from detecting the system `g++` on macOS,
    # fixing builds on some older GHC versions (like `ghc-9.7-start`):
    export CXX=${stdenv.cc}/bin/${stdenv.cc.targetPrefix}c++
    export AR=${stdenv.cc.bintools.bintools}/bin/${stdenv.cc.targetPrefix}ar
    export RANLIB=${stdenv.cc.bintools.bintools}/bin/${stdenv.cc.targetPrefix}ranlib
    export NM=${stdenv.cc.bintools.bintools}/bin/${stdenv.cc.targetPrefix}nm
    export LD=${stdenv.cc.bintools}/bin/${stdenv.cc.targetPrefix}ld
    export LLVMAS=${llvmForGhc}/bin/${stdenv.cc.targetPrefix}clang
    export GHC=$NIX_GHC
    export GHCPKG=$NIX_GHCPKG
    export HAPPY=${hspkgs.happy}/bin/happy
    export ALEX=${hspkgs.alex}/bin/alex
    export CONFIGURE=./configure
    ${lib.optionalString withEMSDK "export EMSDK=${pkgs.emscripten}"}
    ${lib.optionalString withEMSDK "export EMSDK_LLVM=${pkgs.emscripten}/bin/emscripten-llvm"}
    ${ # prevents sub word sized atomic operations not available issues
       # see: https://gitlab.haskell.org/ghc/ghc/-/wikis/javascript-backend/building#configure-fails-with-sub-word-sized-atomic-operations-not-available
      lib.optionalString withEMSDK ''
      unset CC
      CONFIGURE="emconfigure ./configure"
      export EM_CACHE=$(mktemp -d)
      >&2 echo "N.B. You will need to invoke Hadrian with --bignum=native"
      >&2 echo ""
    ''}
    ${lib.optionalString withLlvm "export LLC=${llvmForGhc}/bin/llc"}
    ${lib.optionalString withLlvm "export OPT=${llvmForGhc}/bin/opt"}

    # "nix-shell --pure" resets LANG to POSIX, this breaks "make TAGS".
    export LANG="en_US.UTF-8"
    export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:${lib.makeLibraryPath depsSystem}"

    ${lib.optionalString withDocs "export FONTCONFIG_FILE=${fonts}"}

    # N.B. This overrides CC, CONFIGURE_ARGS, etc. to configure the cross-compiler.
    # See https://gitlab.haskell.org/ghc/ghc-wasm-meta/-/blob/master/pkgs/wasi-sdk-setup-hook.sh
    ${lib.optionalString withWasm' "addWasiSDKHook"}

    >&2 echo "Recommended ./configure arguments (found in \$CONFIGURE_ARGS:"
    >&2 echo "or use the configure_ghc command):"
    >&2 echo ""
    >&2 echo "  ${lib.concatStringsSep "\n  " CONFIGURE_ARGS}"
  '';
}
