{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nixgl.url = "github:nix-community/nixGL";
  };

  outputs = { nixpkgs, flake-utils, nixgl, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
          };
          overlays = [ nixgl.overlay ];
        };
      in {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # build tools and compilers
            gnumake
            cmake
            clang_17
            # CUDA compiler and libraries
            cudaPackages.cuda_nvcc
            cudaPackages.cuda_cudart
            cudaPackages.cuda_cccl
            # C++ libraries
            fmt
            zlib
            pngpp
            argparse
            boost
          ];

          shellHook = ''
            export LD_LIBRARY_PATH=$(${pkgs.nixgl.auto.nixGLDefault}/bin/nixGL printenv LD_LIBRARY_PATH):$LD_LIBRARY_PATH
          '';
        };
        packages = {
          default = pkgs.callPackage ./default.nix { };
          # sudo nix build --out-link /run/opengl-driver .#nvidia --impure
          nvidia = pkgs.nixgl.auto.nvidiaDrivers.out;
        };
      }
    );
}
