{
  lib,
  stdenv,
  autoAddDriverRunpath,

  cmake,

  fmt,
  zlib,
  pngpp,
  argparse,
  boost,

  cudaPackages,
}:

stdenv.mkDerivation {
  pname = "ply2image";
  version = "1.0.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./src
      ./CMakeLists.txt
    ];
  };
  

  nativeBuildInputs = [
    # build tools and compilers
    cmake
    # hooks
    autoAddDriverRunpath # add impure nvidia driver dynamic libraries to RPATH
  ];

  buildInputs = [
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

  cmakeFlags = [
    "-DCMAKE_CUDA_ARCHITECTURES=75"
  ];

  installPhase = ''
    mkdir $out
    install -D ply2image -t $out/bin/
  '';

  meta = with lib; {
    description = "Triangle-Mesh-Rasterization-Projection";
    homepage = "https://github.com/QBV-tu-ilmenau/Triangle-Mesh-Rasterization-Projection";
    license = {
      shortName = "bsdOriginalPaperAttribution";
      free = true;
      fullName = "BSD 4-Clause License with Paper Attribution";
    };
    mainProgram = "ply2image";
  };
}