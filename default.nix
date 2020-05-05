let
  sources = import nix/sources.nix;
in
{ nixpkgs ? sources.nixpkgs, pkgs ? import ./nixpkgs.nix { inherit nixpkgs; nixpkgsMozilla = sources.nixpkgs-mozilla; } }:
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
    runTests = true;
  };

  test =
    (with pkgs.lib;
      import ./test.nix { inherit nixpkgs pkgs server client; }
    );

}
