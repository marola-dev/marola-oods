{
  description = "marola-oods — the Open Ocean Data Store (MIP-0056, split out by MIP-0070)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # Tools, the just module and the lint toolchain. Bump with .github/workflows/*.yml's @tag.
    marola-devkit = {
      url = "github:marola-dev/marola-devkit/v0.5.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, marola-devkit }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        devkit = marola-devkit.lib.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          name = "marola-oods";
          # jq: scripts/etl-inputs-check.sh.
          packages = devkit.tools ++ [ pkgs.jq ];
          shellHook = devkit.shellHook + ''
            git config core.hooksPath .devkit/.githooks 2>/dev/null || true
            echo "marola-oods dev shell. Run 'just' to see available commands."
          '';
        };
      });
}
