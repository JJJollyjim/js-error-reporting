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
      let
        discoverTests = val:
          if !isAttrs val then val
          else if hasAttr "test" val then callTest val
          else mapAttrs (n: s: discoverTests s) val;
        handleTest = path: args:
          discoverTests (import path ({ inherit system pkgs; } // args));
        handleTestOn = systems: path: args:
          if elem system systems then handleTest path args
          else {};
      in
        handleTest ./test.nix { inherit nixpkgs server client; }
    );

}
