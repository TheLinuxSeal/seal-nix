{
  description = "A NixOS machine configured in Seal";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    seal-nix = {
      url = "github:TheLinuxSeal/seal-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, seal-nix, ... }: {
    # sudo nixos-rebuild switch --flake .#seal-machine
    nixosConfigurations.seal-machine = nixpkgs.lib.nixosSystem {
      modules = [
        ./hardware-configuration.nix
        seal-nix.nixosModules.default
        { seal-nix.src = ./config; }
      ];
    };
  };
}
