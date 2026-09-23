# OmniRoute has a workspace-based package-lock.json that references local
# workspace packages (@omniroute/browser-pool, open-sse, packages/browser-pool).
# `buildNpmPackage` uses `npm ci --offline` inside the Nix sandbox, which
# cannot resolve those workspace links. Instead this is built in two stages:
#
#   1. `npmInstall`: a fixed-output derivation that runs
#      `npm install -g omniroute@<version>` with network access. Fixup is
#      disabled so the output is exactly what npm produced (no shebang
#      patching, no store-path references), which keeps `outputHash` stable
#      across nixpkgs updates.
#   2. `omniroute`: a normal derivation that only wraps the installed bins with
#      the matching Node.js, without copying the (multi-GB) tree.
#
# Updating for a new release:
#   1. Set `version` and `publishedAt` (from `npm view omniroute time --json`).
#   2. Set the hash for your system to `lib.fakeHash`, run `nix build`, and copy
#      the "got:" value from the hash-mismatch error.
#
# The npm tree contains platform-specific binaries (sharp, @next/swc, esbuild,
# ...), so there is one hash per system. Only systems listed in `hashes` are
# supported; add yours after building on it.
{
  lib,
  stdenv,
  nodejs,
  cacert,
  makeWrapper,
}: let
  version = "3.8.50";

  # The published tarball has no lockfile, so transitive dependencies would
  # otherwise resolve to whatever is newest at build time and drift the hash.
  # `--before` restricts resolution to versions that existed at release time.
  publishedAt = "2026-08-28T16:19:48.276Z";

  hashes = {
    x86_64-linux = "sha256-JbdJndoVHtw1juTQmC9qIXVfwn8IER6Z/wblY2VlacA=";
  };

  npmInstall = stdenv.mkDerivation {
    pname = "omniroute-npm-install";
    inherit version;

    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    dontFixup = true;

    nativeBuildInputs = [nodejs cacert];

    installPhase = ''
      runHook preInstall
      export HOME="$NIX_BUILD_TOP/home"
      mkdir -p "$HOME" "$out"
      export npm_config_cache="$NIX_BUILD_TOP/.npm-cache"
      export npm_config_prefix="$out"
      export npm_config_userconfig="$HOME/.npmrc"
      export npm_config_globalconfig="$HOME/.npmrc-global"
      export SSL_CERT_FILE="${cacert}/etc/ssl/certs/ca-bundle.crt"
      npm install -g \
        --no-audit --no-fund --no-update-notifier \
        --ignore-scripts \
        --before=${publishedAt} \
        omniroute@${version}
      runHook postInstall
    '';

    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = hashes.${stdenv.hostPlatform.system} or lib.fakeHash;
  };

  lib' = "${npmInstall}/lib/node_modules/omniroute";
in
  stdenv.mkDerivation {
    pname = "omniroute";
    inherit version;

    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;

    nativeBuildInputs = [makeWrapper];

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      makeWrapper ${nodejs}/bin/node $out/bin/omniroute \
        --add-flags ${lib'}/bin/omniroute.mjs \
        --prefix PATH : ${lib.makeBinPath [nodejs]}
      makeWrapper ${nodejs}/bin/node $out/bin/omniroute-reset-password \
        --add-flags ${lib'}/bin/reset-password.mjs \
        --prefix PATH : ${lib.makeBinPath [nodejs]}
      runHook postInstall
    '';

    passthru = {inherit npmInstall;};

    meta = with lib; {
      description = "Unified AI router with automatic provider fallback";
      homepage = "https://github.com/diegosouzapw/OmniRoute";
      license = licenses.mit;
      platforms = builtins.attrNames hashes;
      mainProgram = "omniroute";
    };
  }
