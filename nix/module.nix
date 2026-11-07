# seal-nix as a NixOS module, which a system's flake adds as it would home-manager's:
#
#   inputs.seal-nix = { url = "github:TheLinuxSeal/seal-nix"; inputs.nixpkgs.follows = "nixpkgs"; };
#   modules = [ seal-nix.nixosModules.default { seal-nix.src = ./config/Main.seal; } ];
#
# The Seal configuration in seal-nix.src sets the system's options, with the options and packages of
# the system's own nixpkgs.
{ generateWith }:
{ config, lib, options, pkgs, modulesPath, ... }:
let
  cfg = config.seal-nix;

  # The platforms, as the system's own modules define them (hardware-configuration.nix does), read
  # from their definitions: config.nixpkgs.hostPlatform's default can read options Seal sets
  # (hardware.facter), and Seal can't run before Nix knows where.
  systemOf = p: if builtins.isString p then p else p.system;
  defined = name:
    let o = options.nixpkgs.${name} or null; in
    if o != null && o.highestPrio < 1500 then systemOf (lib.last o.definitions) else null;
  firstOf = lib.findFirst (s: s != null) null;
  hostSystem = firstOf [ cfg.system (defined "hostPlatform") (defined "localSystem") (defined "system") ];
  buildSystem = firstOf [ (defined "buildPlatform") hostSystem ];
  system =
    if buildSystem != null then buildSystem
    else throw "seal-nix: set nixpkgs.hostPlatform (hardware-configuration.nix does), or seal-nix.system";

  # NixOS from this system's nixpkgs, on its own: what the Seal configuration may name, and the
  # types. Not this system's own options, whose types and defaults may depend on what Seal sets.
  # It has the system's specialArgs (inputs, say), which modules may need to declare their options,
  # and its overlays, so that Packages has their packages.
  nixos = import (modulesPath + "/../lib/eval-config.nix") {
    system = null;
    specialArgs = config._module.specialArgs;
    modules = [{
      nixpkgs.hostPlatform = hostSystem;
      nixpkgs.overlays = if cfg.systemOverlays then config.nixpkgs.overlays else [ ];
    }] ++ cfg.extraModules;
  };

  generated = generateWith { inherit system nixos; inherit (cfg) src; };
  module = import generated { inherit config lib options pkgs modulesPath; };

  # What the generated module sets at path, as this module's definition of it. The names this
  # module defines are fixed (every top-level option), and only their values come from Seal, so that
  # NixOS can tell what it defines without running Seal, which needs seal-nix.src and the platform.
  from = path:
    if cfg.src == null then lib.mkMerge [ ]
    else lib.mkMerge (lib.optional (lib.hasAttrByPath path module) (lib.getAttrFromPath path module));

  # What NixOS must know before Seal can run, which only Nix sets: the platforms
  # (hardware-configuration.nix), what NixOS reads to decide them (nixpkgs.pkgs, a NixOS test's, and
  # hardware.facter), the overlays, which Packages has, and programs.ccache, which decides whether
  # NixOS adds one. This module defines the other names of these namespaces, one level down.
  nixOnly = {
    nixpkgs = [ "hostPlatform" "buildPlatform" "localSystem" "crossSystem" "system" "pkgs" "overlays" ];
    hardware = [ "facter" ];
    programs = [ "ccache" ];
  };

  topLevel = lib.filter (n: !(lib.elem n [ "_module" "seal-nix" ])) (lib.attrNames options);

  definitions = lib.genAttrs topLevel (n:
    if nixOnly ? ${n} then
      lib.genAttrs (lib.filter (c: !(lib.elem c nixOnly.${n})) (lib.attrNames options.${n})) (c: from [ n c ])
    else from [ n ]);

  nixOnlySet = lib.concatLists (lib.mapAttrsToList
    (n: cs: map (c: "${n}.${c}") (lib.filter (c: lib.hasAttrByPath [ n c ] module) cs)) nixOnly);
in
{
  options.seal-nix = {
    src = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./config/Main.seal";
      description = ''
        The Seal configuration's entry file, a path: ./config/Main.seal. Its class's main() runs, and
        sets Config's options; the classes it names (Users.add()) come from the .seal files of the
        same name beside it, and the ones those name, and so on. A folder works too: all its .seal
        files, with Main.seal the entry.
      '';
    };

    system = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "x86_64-linux";
      description = ''
        The system the machine runs, for a configuration whose modules don't set nixpkgs.hostPlatform.
      '';
    };

    extraModules = lib.mkOption {
      type = lib.types.listOf lib.types.raw;
      default = [ ];
      example = lib.literalExpression "[ home-manager.nixosModules.home-manager ]";
      description = ''
        Modules beyond NixOS's own whose options the Seal configuration sets. Import them into the
        system too.
      '';
    };

    systemOverlays = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether Packages has the packages of the system's nixpkgs.overlays, as it has nixpkgs's.
        Turn it off if a module adds an overlay only when an option the Seal configuration sets is
        on: Nix would need Seal's settings to know the overlays, and the overlays to run Seal, and
        stops with "infinite recursion". Pkg.of("name") still reaches any package.
      '';
    };

    generated = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = ''
        The NixOS module the Seal configuration made, as a .nix file:
        nix build .#nixosConfigurations.<name>.config.seal-nix.generated
      '';
    };
  };

  config = definitions // {
    seal-nix.generated = lib.mkIf (cfg.src != null) generated;

    assertions = lib.mkMerge [
      (from [ "assertions" ])
      [{
        assertion = cfg.src == null || nixOnlySet == [ ];
        message = "seal-nix: ${lib.concatStringsSep ", " nixOnlySet} must be set in Nix (hardware-configuration.nix), not Seal: NixOS needs it before Seal runs.";
      }]
    ];
  };
}
