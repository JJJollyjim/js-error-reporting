let
  sources = import nix/sources.nix;
in
{ nixpkgs ? sources.nixpkgs, nixpkgsMozilla ? sources.nixpkgs-mozilla }:
let
  rustChannelsOverlay = import "${nixpkgsMozilla}/rust-overlay.nix";
  # Useful if you also want to provide that in a nix-shell since some rust tools depend
  # on that.
  rustChannelsSrcOverlay = import "${nixpkgsMozilla}/rust-src-overlay.nix";
in
import nixpkgs {
  overlays = [
    rustChannelsOverlay
    rustChannelsSrcOverlay
    (self: super: {
      rustc = super.latest.rustChannels.nightly.rust;
      inherit (super.latest.rustChannels.nightly) cargo rust rust-fmt rust-std clippy;
    }
    )
  ];
}
