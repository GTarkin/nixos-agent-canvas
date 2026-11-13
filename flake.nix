{
  description = "NixOS-based Agent Canvas guest for systemd-nspawn";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
        };

      # Beispiel-Gast: so startet ihn nixosModules.host auf dem Wirt.
      guestModules = [
        self.nixosModules.guest
        { services.agent-canvas.enable = true; }
      ];
    in
    {
      nixosModules = {
        guest = ./nixos/modules/guest.nix;
        host = ./nixos/modules/host.nix;
        default = self.nixosModules.guest;
      };

      nixosConfigurations.agent-canvas-guest = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = guestModules;
      };

      checks = forAllSystems (system: {
        # Der Closure IST das Artefakt — kein Image, kein Digest. Baut er,
        # startet der Gast.
        guest = self.nixosConfigurations.agent-canvas-guest.config.system.build.toplevel;

        # Evaluiert nixosModules.host gegen eine minimale Wirts-Konfiguration
        # und prüft, dass daraus ein Container mit Binds + Port entsteht.
        host-module =
          (nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.host
              {
                system.stateVersion = "25.11";
                boot.loader.grub.enable = false;
                fileSystems."/" = {
                  device = "none";
                  fsType = "tmpfs";
                };
                services.agent-canvas-host.enable = true;
                services.agent-canvas-host.instances.demo = {
                  port = 8000;
                  hostPort = 8001;
                  workspaceDir = "/srv/agent-canvas/demo/projects";
                  stateDir = "/srv/agent-canvas/demo/state";
                };
              }
            ];
          }).config.containers."agent-canvas-demo".config.system.build.toplevel;
      });

      devShells = forAllSystems (system: {
        default = (pkgsFor system).mkShell {
          packages = with (pkgsFor system); [
            nixfmt-rfc-style
            nodejs_24
            uv
          ];
        };
      });

      formatter = forAllSystems (system: (pkgsFor system).nixfmt-rfc-style);
    };
}
