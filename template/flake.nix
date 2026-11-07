{
  description = "A NixOS machine configured in Seal";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    sealnix = {
      url = "github:TheLinuxSeal/seal-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, sealnix, ... }: {
    # sudo nixos-rebuild switch --flake .#seal-machine
    nixosConfigurations.seal-machine = nixpkgs.lib.nixosSystem {
      modules = [
        ./hardware-configuration.nix
        (sealnix.lib.module { system = "x86_64-linux"; src = ./config; inherit nixpkgs; })
      ];
    };
  };
}
