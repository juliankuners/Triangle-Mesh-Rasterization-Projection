{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };
      in {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # build tools and compilers
            gnumake
            cmake
            clang_17
            # C++ libraries
            fmt
            zlib
            pngpp
            argparse
            boost
          ];
        };
        packages.default = pkgs.callPackage ./default.nix { };
      }
    );
}
