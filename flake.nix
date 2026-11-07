{
  description = "SealNix: NixOS configured in Seal, with every option and package under its Nix name";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    seal = {
      url = "github:TheLinuxSeal/seal-lang";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, seal }:
    let
      inherit (nixpkgs) lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});

      # The host: Java that uses Seal's embed API to generate, compile and run a configuration (host/SealNix.java).
      hostFor = pkgs: sealPkg: pkgs.stdenv.mkDerivation {
        pname = "sealnix-host";
        version = "0.1.0";
        src = ./host;
        strictDeps = true;
        nativeBuildInputs = [ pkgs.jdk25_headless pkgs.makeWrapper ];
        buildPhase = ''
          runHook preBuild
          javac -cp ${sealPkg}/share/seal/classes -d classes SealNix.java
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p $out/share/sealnix
          cp -r classes runtime $out/share/sealnix/
          makeWrapper ${lib.getExe' pkgs.jdk25_headless "java"} $out/bin/sealnix-host \
            --add-flags "-Dseal.stdlib=${sealPkg}/share/seal/stdlib" \
            --add-flags "-cp ${sealPkg}/share/seal/classes:$out/share/sealnix/classes" \
            --add-flags "SealNix $out/share/sealnix/runtime"
          runHook postInstall
        '';
        meta.mainProgram = "sealnix-host";
      };

      # The NixOS module a Seal configuration makes, as a .nix file.
      #   system  where the generator runs
      #   src     the configuration's entry file (./config/Main.seal), whose class's main() sets
      #           Config's options; or its folder, whose entry is Main.seal (nix/sources.nix)
      #   nixos   a NixOS evaluated on its own, whose options and packages the configuration may use
      generateWith = { system, src, nixos }:
        let
          buildPkgs = self.inputs.nixpkgs.legacyPackages.${system};
          sources = import ./nix/sources.nix { inherit lib; } src;
          spec = import ./nix/spec.nix { inherit (nixos.pkgs) lib; inherit (nixos) options pkgs; } sources.files;
        in
        buildPkgs.runCommand "sealnix-module.nix"
          {
            nativeBuildInputs = [ self.packages.${system}.host ];
            spec = builtins.toJSON (spec // { inherit (sources) main; });
            passAsFile = [ "spec" ];
          }
          ''
            sealnix-host "$specPath" ${sources.dir} > $out
          '';

      # As generateWith, with the options and packages of a nixpkgs flake (this one's, unless given),
      # and of extraModules, modules that declare more options (home-manager's, say).
      generate = { system, src, nixpkgs ? self.inputs.nixpkgs, extraModules ? [ ] }:
        generateWith {
          inherit system src;
          nixos = nixpkgs.lib.nixosSystem { modules = [{ nixpkgs.hostPlatform = system; }] ++ extraModules; };
        };
    in
    {
      # modules = [ seal-nix.nixosModules.default { seal-nix.src = ./config/Main.seal; } ], as home-manager's
      # module is added. Nix runs the Seal program while it evaluates the system (import from derivation).
      nixosModules.default = import ./nix/module.nix { inherit generateWith; };
      nixosModules.seal-nix = self.nixosModules.default;

      lib = {
        inherit generate generateWith;

        # The configuration as a module of its own, without the seal-nix options:
        #   (seal-nix.lib.module { system = "x86_64-linux"; src = ./config; inherit nixpkgs; })
        module = args: import (generate args);
      };

      packages = forAllSystems (system: pkgs: {
        host = hostFor pkgs seal.packages.${system}.default;
        seal = seal.packages.${system}.default;

        # sealnix FOLDER [OUT.nix]: the module the configuration in FOLDER makes, printed or written to OUT.nix.
        default = pkgs.writeShellApplication {
          name = "sealnix";
          text = ''
            if [ $# -lt 1 ] || [ $# -gt 2 ]; then
              echo "usage: sealnix FOLDER [OUT.nix]   the NixOS module the Seal configuration in FOLDER makes" >&2
              exit 2
            fi
            src=$(realpath "$1")
            module=$(nix --extra-experimental-features "nix-command flakes" build --no-link --print-out-paths --impure \
              --expr "(builtins.getFlake \"path:${self}\").lib.generate { system = \"${system}\"; src = /. + \"$src\"; }")
            if [ $# -eq 2 ]; then
              install -m 644 "$module" "$2"
              echo "sealnix: wrote $2" >&2
            else
              cat "$module"
            fi
          '';
        };

        # nix build .#example: the module example/Main.seal makes.
        example = generate { inherit system; src = ./example/Main.seal; };

        # nix build .#vm-test: boots a virtual machine configured by tests/vm/Main.seal, and checks
        # from the inside that what the Seal program set is so. Needs KVM, and downloads about 1 GiB.
        vm-test = pkgs.testers.runNixOSTest {
          name = "sealnix-vm";
          nodes.machine = {
            imports = [ self.nixosModules.default ];
            seal-nix.src = ./tests/vm/Main.seal;
          };
          testScript = ''
            machine.wait_for_unit("multi-user.target")
            machine.wait_for_unit("hello.service")
            assert machine.succeed("cat /run/hello").strip() == "hello from Seal"
            assert machine.succeed("hostname").strip() == "sealbox"
            machine.wait_for_unit("sshd.service")
            machine.succeed("command -v fastfetch")
            machine.succeed("id seal | grep -q wheel")
            machine.succeed("su - seal -c 'cowsay moo'")
            assert "from Seal" in machine.succeed("su - seal -c 'echo $SEALNIX'")
          '';
        };
      });

      apps = forAllSystems (system: pkgs: {
        default = { type = "app"; program = lib.getExe self.packages.${system}.default; };
      });

      # The example as a whole system: nix build .#nixosConfigurations.example.config.system.build.vm
      # makes a virtual machine of it, which ./result/bin/run-sealbox-vm starts.
      nixosConfigurations.example = lib.nixosSystem {
        modules = [
          ./example/hardware.nix
          self.nixosModules.default
          { seal-nix.src = ./example/Main.seal; }
        ];
      };

      checks = forAllSystems (system: pkgs: {
        example = self.packages.${system}.example;
        # a folder: all of its .seal files, with Main.seal the entry
        features = generate { inherit system; src = ./tests/features; };

        # two machines from one folder, each its entry and the classes it names
        machines = pkgs.runCommand "machines" { } ''
          main=${generate { inherit system; src = ./tests/machines/Main.seal; }}
          laptop=${generate { inherit system; src = ./tests/machines/Laptop.seal; }}
          head -1 $main | grep -q "from Desktop.seal, Main.seal, Users.seal:"
          grep -q 'hostName = "sealbox"' $main
          grep -q 'plasma6.enable = true' $main
          ! grep -q tlp $main
          head -1 $laptop | grep -q "from Laptop.seal, Users.seal:"
          grep -q 'hostName = "seal-laptop"' $laptop
          grep -q 'tlp.enable = true' $laptop
          ! grep -q plasma6 $laptop
          grep -q 'extraGroups = \[ "wheel" \]' $laptop
          touch $out
        '';
      } // lib.optionalAttrs (system == "x86_64-linux") {
        example-system = pkgs.writeText "example-system"
          (builtins.unsafeDiscardStringContext self.nixosConfigurations.example.config.system.build.toplevel.drvPath);
        features-system = pkgs.writeText "features-system" (builtins.unsafeDiscardStringContext
          (lib.nixosSystem {
            modules = [ ./example/hardware.nix self.nixosModules.default { seal-nix.src = ./tests/features; } ];
          }).config.system.build.toplevel.drvPath);

        # lib.module, the configuration as a module of its own
        lib-module-system = pkgs.writeText "lib-module-system" (builtins.unsafeDiscardStringContext
          (lib.nixosSystem {
            modules = [ ./example/hardware.nix (self.lib.module { inherit system; src = ./example; }) ];
          }).config.system.build.toplevel.drvPath);
      });

      templates.default = {
        path = ./template;
        description = "A NixOS machine configured in Seal";
      };

      devShells = forAllSystems (system: pkgs: {
        default = pkgs.mkShell {
          packages = [ seal.packages.${system}.default self.packages.${system}.default ];
        };
      });
    };
}
