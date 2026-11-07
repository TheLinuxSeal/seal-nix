# What a real machine's hardware-configuration.nix gives (nixos-generate-config writes it), so that
# the example evaluates as a whole system and builds as a virtual machine.
{
  nixpkgs.hostPlatform = "x86_64-linux";
  fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
  fileSystems."/boot" = { device = "/dev/disk/by-label/boot"; fsType = "vfat"; };
  system.stateVersion = "26.05";
}
