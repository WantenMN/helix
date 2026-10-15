{ stdenv
, lib
, fetchurl
, autoPatchelfHook
, makeWrapper
}:

# Helix fork (traditional tarball from GitHub Release).
# Generated + verified by CI (.github/workflows/fork-tarball.yml):
#   version/url/hash are filled in by CI on every push to release_fork and
#   uploaded as release asset `helix-fork.nix`. This file in dotfiles is a
#   copy fetched by pkgs/update-fork-tarballs.sh — do not edit hash by hand.
stdenv.mkDerivation rec {
  pname = "helix-fork";
  version = "0.0.0-unset";

  src = fetchurl {
    url = "https://github.com/WantenMN/helix/releases/download/fork-linux-x86_64/helix-linux-x86_64.tar.gz";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];

  # Tarball top level is bin/ share/ (no usr/ wrapper).
  # Binary is built with HELIX_DEFAULT_RUNTIME=/usr/share/helix/runtime for
  # FHS installs; here we redirect via the HELIX_RUNTIME env var.
  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r bin share $out/

    wrapProgram $out/bin/hx \
      --set HELIX_RUNTIME $out/share/helix/runtime

    runHook postInstall
  '';

  meta = {
    description = "Helix post-modern text editor (fork prebuilt tarball)";
    homepage = "https://github.com/WantenMN/helix";
    license = lib.licenses.mpl20;
    platforms = [ "x86_64-linux" ];
    mainProgram = "hx";
  };
}
