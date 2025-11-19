{
  description = "Serokell Openbao Tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      forSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-darwin"
      ];
    in
    {
      overlays.default = final: prev: {
        openbao-push-approles = final.callPackage ./scripts/openbao-push-approles.nix { };
        openbao-push-approle-envs = final.callPackage ./scripts/openbao-push-approle-envs.nix { };
      };

      nixosModules.openbao-secrets = import ./modules/openbao-secrets.nix;
      darwinModules.openbao-secrets = import ./modules/openbao-secrets-darwin.nix;

      checks = forSystems (
        system:
        let
          tests = import ./tests/modules/all-tests.nix {
            pkgs = nixpkgs.legacyPackages.${system};
            inherit system self;
            callTest = t: t.test;
            nixosPath = "${nixpkgs}/nixos";
          };
        in
        {
          inherit (tests) openbao-secrets;
        }
      );

      legacyPackages = forSystems (system: nixpkgs.legacyPackages.${system}.extend self.overlays.default);
    };
}
