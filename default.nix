let
  sources = import nix/sources.nix;
in
#{ rustChannel ? ((pkgs.extend (import "${sources.nixpkgs-mozilla}/rust-overlay.nix")).latest.rustChannels.nightly), pkgs ? import sources.nixpkgs {} }:
{ pkgs }:
with pkgs;
with lib;
rec {
  client = { appName, reportingUrl }: stdenvNoCC.mkDerivation {
    inherit appName reportingUrl;
    name = "report-error.js";
    src = ./clientSrc;
    buildPhase = ''
      substituteAllInPlace report-error.js
      ${pkgs.minify}/bin/minify report-error.js > $out
    '';
    dontInstall = true;
  };

  server = (pkgs.callPackage ./server/Cargo.nix {}).rootCrate.build.override {
  #server = ((pkgs.extend (super: self: { rustc = rustChannel.rust; inherit (rustChannel) cargo rust rust-fmt rust-std clippy; })).callPackage ./server/Cargo.nix {}).rootCrate.build.override {
    runTests = true;
  };

  test = pkgs.callPackage ./test.nix { inherit server client; };
}
