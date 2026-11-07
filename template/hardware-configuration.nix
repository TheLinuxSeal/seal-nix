# On a real machine, replace this with the one NixOS made: /etc/nixos/hardware-configuration.nix.
# This one is enough to build a virtual machine of the configuration:
#   nix build .#nixosConfigurations.seal-machine.config.system.build.vm && ./result/bin/run-*-vm
{
  nixpkgs.hostPlatform = "x86_64-linux";
  fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
  fileSystems."/boot" = { device = "/dev/disk/by-label/boot"; fsType = "vfat"; };
  system.stateVersion = "26.05";
}
