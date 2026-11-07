# seal-nix

NixOS, configured in [Seal](https://github.com/TheLinuxSeal/seal-lang). Every NixOS option and
every nixpkgs package is there under its Nix name, with its type, checked when Seal compiles. The
configuration becomes an ordinary `.nix` module, and NixOS builds it as usual.

```java
import sealnix.*;

class Main {
    static void main() {
        Config.networking.hostName = "sealbox";
        Config.services.openssh.enable = true;
        Config.services.openssh.settings.PermitRootLogin = "no";
        Config.boot.loader.systemd_boot.enable = true;
        Config.environment.systemPackages.add(Packages.fastfetch);
        Config.environment.systemPackages.add(Packages.kdePackages.kate);
        Config.users.users.seal.isNormalUser = true;
        Config.users.users.seal.extraGroups.add("wheel");
    }
}
```

```nix
{ config, lib, pkgs, ... }:
{
  boot.loader.systemd-boot.enable = true;
  environment.systemPackages = [ pkgs.fastfetch pkgs.kdePackages.kate ];
  networking.hostName = "sealbox";
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "no";
  };
  users.users.seal = {
    extraGroups = [ "wheel" ];
    isNormalUser = true;
  };
}
```

A mistake is a compile error, with a suggestion:

```text
Main.seal:5:9: Config has no member services
Main.seal:7:38: assignment: expected string, found integer constant 42
note: Config.services has no option opensh; did you mean openssh, opkssh?
note: Packages has no package fastfech; did you mean fastfetch?
```

[`example/Main.seal`](example/Main.seal) is a whole machine, and
[`tests/features/Main.seal`](tests/features/Main.seal) uses every kind of option there is.

## Using it

The commands need flakes: `--extra-experimental-features "nix-command flakes"`, or turn them on in `nix.conf`.

**Add it to your system's flake**, as you would home-manager:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    seal-nix = {
      url = "github:TheLinuxSeal/seal-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, seal-nix, ... }: {
    nixosConfigurations.my-machine = nixpkgs.lib.nixosSystem {
      modules = [
        ./configuration.nix                 # yours, as it is
        seal-nix.nixosModules.default
        { seal-nix.src = ./config/Main.seal; }   # a path: no quotes
      ];
    };
  };
}
```

Then `sudo nixos-rebuild switch --flake .#my-machine`. What the Seal program sets merges with
`configuration.nix` as any module's settings do, so a system can move to Seal an option at a time.
The options and packages Seal can name are those of the system's own nixpkgs.

| Option | |
| --- | --- |
| `seal-nix.src` | The Seal configuration's entry file, `./config/Main.seal`: its class's `main()` runs and sets `Config`'s options (see [Several files](#several-files-and-machines)). A folder works too: all its `.seal` files, entry `Main.seal`. |
| `seal-nix.extraModules` | Modules beyond NixOS's own whose options Seal sets, as `[ home-manager.nixosModules.home-manager ]`; import them into the system too. |
| `seal-nix.system` | The machine's system, only for one whose modules don't set `nixpkgs.hostPlatform`. |
| `seal-nix.generated` | The module the Seal configuration made, to read: `nix build .#nixosConfigurations.my-machine.config.seal-nix.generated && cat result`. |

The platforms (`nixpkgs.hostPlatform` and the like), `nixpkgs.pkgs` and `hardware.facter` stay in Nix
(`hardware-configuration.nix` sets them): NixOS needs them before it can run Seal. Nix runs the Seal
program while it evaluates the system (import from derivation), so setups with
`allow-import-from-derivation = false` refuse it.

On a NixOS machine, `/etc/nixos` then holds:

```
/etc/nixos/
├── flake.nix                    nixpkgs, seal-nix, and nixosConfigurations.<hostname>
├── flake.lock                   written by the first rebuild
├── hardware-configuration.nix   from nixos-generate-config, as it is
├── configuration.nix            what stays in Nix: imports the hardware file, system.stateVersion
└── config/
    ├── Main.seal                seal-nix.src = ./config/Main.seal;
    ├── Users.seal               Users.add() in Main.seal brings this in
    └── Desktop.seal             Desktop.main() this
```

`sudo nixos-rebuild switch` builds the configuration named after the machine's hostname, so name the
flake's `nixosConfigurations.<name>` as `Config.networking.hostName` names the machine. Flakes are off
on a fresh install: the first time, `sudo env NIX_CONFIG="experimental-features = nix-command flakes"
nixos-rebuild switch`, and have the Seal configuration turn them on for good
(`Config.nix.settings.experimental_features.add("flakes")`). If `/etc/nixos` is a git repository,
`git add` new `.seal` files: a flake sees only what git tracks.

**A new machine:** `nix flake init -t github:TheLinuxSeal/seal-nix` in an empty folder gives
[`template/`](template), the flake above with `config/Main.seal` to write. Put your machine's
`/etc/nixos/hardware-configuration.nix` beside it. On any Linux with Nix (Ubuntu too), build it as a
virtual machine and boot it:

```sh
nix build .#nixosConfigurations.seal-machine.config.system.build.vm && ./result/bin/run-seal-machine-vm
```

**Just the `.nix` file:** `nix run github:TheLinuxSeal/seal-nix -- FOLDER` prints the module the
configuration in FOLDER makes, and `nix run github:TheLinuxSeal/seal-nix -- FOLDER out.nix` writes it.
In Nix, `seal-nix.lib.generate { system = "x86_64-linux"; src = ./config; }` is that file.

In a clone of this repository: `nix build .#example`; `nix build .#nixosConfigurations.example.config.system.build.vm`;
`nix flake check`, which converts the example and the feature test and evaluates both as whole systems;
and `nix build .#vm-test`, which boots a machine that [`tests/vm/Main.seal`](tests/vm/Main.seal)
configures and checks, inside it, that what it set is so (KVM, and about 1 GiB of downloads).
`git add` new files before trying them: a flake sees only what git tracks.

## Writing a configuration

`Config` is NixOS's options, `Packages` nixpkgs. Names are Nix's, with `_` where Nix allows what Seal
doesn't, and after a Seal keyword:

| Nix | Seal |
| --- | --- |
| `services.openssh.enable = true;` | `Config.services.openssh.enable = true;` |
| `boot.loader.systemd-boot.enable = true;` | `Config.boot.loader.systemd_boot.enable = true;` |
| `programs.git.package = pkgs.gitFull;` | `Config.programs.git.package_ = Packages.gitFull;` |
| `environment.systemPackages = [ pkgs.git ];` | `Config.environment.systemPackages.add(Packages.git);` |
| `pkgs.nerd-fonts.jetbrains-mono` | `Packages.nerd_fonts.jetbrains_mono`; while running, `Pkg.of("nerd-fonts.jetbrains-mono")` |
| `users.users.seal.isNormalUser = true;` | `Config.users.users.seal.isNormalUser = true;`, or `.get("seal")` |
| `fileSystems."/data".device = "/dev/sdb1";` | `Config.fileSystems.get("/data").device = "/dev/sdb1";` |
| `swapDevices = [ { device = "/swapfile"; } ];` | `Config.swapDevices.add().device = "/swapfile";` |
| `services.openssh.settings.UseDns = true;` | the same, or, for a setting the module doesn't declare, `settings.set("UseDns", true)` |
| `systemd.services.x.serviceConfig.Type = "oneshot";` | the same; `serviceConfig.set("RestartSec", 5)` for a number |
| `boot.kernelPackages = pkgs.linuxPackages_latest;` | `Config.boot.kernelPackages = Nix.raw("pkgs.linuxPackages_latest");` |

Where two Nix names would be one Seal name, the one NixOS's manual shows wins:
`Config.services.oauth2_proxy` is `services.oauth2-proxy`, not its old name `services.oauth2_proxy`
(the only such pair in NixOS).

Types follow the options': `bool` is `bit`, the integers `int<<64>>`, strings and paths `string`,
`package` is `Pkg`, `listOf` a `List`, `attrsOf` a set with `get` and `set` (and a field for each name
the program writes), and a `submodule` an object. An option that may be one of several types takes
the most usual of them, a string before a number. Untyped options take their default value's type,
and the rest (functions, `anything`, `raw`) take a `Nix` value: `Nix.raw("...")`, `Nix.of(...)`,
`Nix.attrs().set("key", value)`. NixOS checks the values themselves (an enum's, a range's) when it
reads the module.

Two ways around everything: `Config.set("services.foo.bar", value)` sets any option by its path,
and `Config.setRaw("services.foo.bar", "lib.mkForce true")` with Nix code.

### Several files, and machines

`seal-nix.src` names the entry, and its class's `main()` is what runs: `./config/Main.seal` runs
`Main.main()`. Seal keeps each class in a file named after it, so the classes the entry names come
from the files of those names beside it, and the classes those name, and so on:

```java
// config/Main.seal
import sealnix.*;

class Main {
    static void main() {
        Config.networking.hostName = "sealbox";
        Users.add();          // config/Users.seal
        Desktop.main();       // config/Desktop.seal
    }
}
```

```java
// config/Users.seal
import sealnix.*;

class Users {
    public static void add() {          // members are private unless public
        Config.users.users.seal.isNormalUser = true;
        Config.users.users.seal.extraGroups.add("wheel");
    }
}
```

A file nothing names isn't part of the configuration, isn't compiled, and can't break it. So one
folder can hold several machines, each an entry of its own that shares the rest:
`seal-nix.src = ./config/Laptop.seal;` runs `Laptop.main()`, which may call `Users.add()` too.
[`tests/machines`](tests/machines) is two such machines. (A file is named when its class's name
appears in another's text, comments too, so a comment can bring one in; it compiles, but only what
the entry's `main()` calls sets anything.)

### home-manager, Hyprland, and other modules

All of NixOS's own modules are there: `Config.programs.hyprland.enable = true;`. Another flake's
NixOS module is too, once seal-nix knows of it through `seal-nix.extraModules` (the system imports it
as well), home-manager's say:

```nix
modules = [
  home-manager.nixosModules.home-manager
  seal-nix.nixosModules.default
  {
    seal-nix.src = ./config/Main.seal;
    seal-nix.extraModules = [ home-manager.nixosModules.home-manager ];
  }
];
```

```java
Config.home_manager.users.seal.home.stateVersion = "26.05";      // home-manager is home_manager in Seal
Config.home_manager.users.seal.home.packages.add(Packages.fastfetch);
Config.home_manager.users.seal.programs.git.enable = true;
Config.home_manager.users.seal.programs.git.settings.set("user", Nix.attrs().set("name", "seal"));
Config.home_manager.users.seal.wayland.windowManager.hyprland.enable = true;
Config.home_manager.users.seal.wayland.windowManager.hyprland.settings.set("general", Nix.attrs().set("gaps_in", 5));
```

Free-form settings, as git's and Hyprland's are, take `.set(key, value)`. Standalone home-manager
(`homeConfigurations`, `home-manager switch`) isn't one of them: seal-nix makes NixOS modules.

### Values

The program is ordinary Seal: loops, methods, other classes and files all work, and reading an option
it set gives the value. Reading one it didn't set gives a placeholder, not NixOS's default. Seal has
no `var` yet; for a variable, the generated classes are named after their paths, `<name>` being
`entry` and a list's element `item`:

```java
Config.systemd_services_entry hello = Config.systemd.services.get("hello");
hello.script = "echo hello from Seal";
hello.wantedBy.add("multi-user.target");
```

## How it works

NixOS has about 30 000 options and nixpkgs over 100 000 packages: far too many for one Seal library,
which a JVM class can't hold and which would take minutes to compile every time. So each
configuration gets a library of its own, of what it uses:

1. [`nix/spec.nix`](nix/spec.nix) reads the `.seal` files for each `Config.a.b.c` and `Packages.x.y`
   they write, and finds them in NixOS's options (of the nixpkgs given) and in nixpkgs, with each
   option's type. A namespace named on its own (`Config.services`) brings all of its options. Every
   one of NixOS's 28 998 options compiles this way, but all of them at once take four minutes; a
   whole machine's configuration takes a couple of seconds.
2. [`host/SealNix.java`](host/SealNix.java), with Seal's embed API, generates the Seal classes for
   those, compiles them with [`host/runtime`](host/runtime/sealnix) and the configuration, and runs its `main()`.
3. Seal can't tell an option the program assigned from one it left alone, so the host compiles and runs
   it twice, each option starting at another value each time: `false` then `true`, `0` then `1`.
   What ends the same both times is what the program set, and is what the module holds.

## License

GPL-3.0, as Seal's: [`LICENSE`](LICENSE).
