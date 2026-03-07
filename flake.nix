{
  description = "MineSynth; the Netlist to Minecraft redstone synthesizer";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = inputs @ { self, nixpkgs, flake-utils, ... }:
  flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs {
        inherit system;
      };
    in {
      devShells.default = pkgs.mkShell rec {
        packages = [
          pkgs.zig
          pkgs.zls
          pkgs.yosys
          pkgs.aiger
          pkgs.graphviz

          (pkgs.writeShellScriptBin "gr-zig" ''
            zig build run |& ${pkgs.graphviz}/bin/dot -Txlib
          '')
          (pkgs.writeShellScriptBin "gr-stdin" ''
            cat /dev/stdin | ${pkgs.graphviz}/bin/dot -Txlib
          '')
          (pkgs.writeShellScriptBin "gr-aag" ''
            aigtodot $1 | ${pkgs.graphviz}/bin/dot -Txlib
          '')
        ];
      };
    }
  );
}
