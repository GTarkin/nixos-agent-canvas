{
  description = "Tests für nixos-agent-canvas (Nutzung als Flake-Input)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Der Sinn dieses Flakes: prüfen, dass das Projekt als Input funktioniert,
    # nicht nur aus sich selbst heraus.
    agent-canvas.url = "path:..";
  };

  outputs =
    {
      self,
      nixpkgs,
      agent-canvas,
    }:
    {
      checks.x86_64-linux = {
        # Der Gast baut (Closure = Artefakt).
        guest = agent-canvas.nixosConfigurations.agent-canvas-guest.config.system.build.toplevel;

        # Ein Wirt mit zwei Instanzen baut und erzeugt beide Container.
        two-instances =
          (nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            modules = [
              agent-canvas.nixosModules.host
              {
                system.stateVersion = "25.11";
                boot.loader.grub.enable = false;
                fileSystems."/" = {
                  device = "none";
                  fsType = "tmpfs";
                };
                services.agent-canvas-host = {
                  enable = true;
                  instances = {
                    alpha = {
                      hostPort = 8011;
                      workspaceDir = "/srv/agent-canvas/alpha/projects";
                      stateDir = "/srv/agent-canvas/alpha/state";
                    };
                    beta = {
                      hostPort = 8012;
                      workspaceDir = "/srv/agent-canvas/beta/projects";
                      stateDir = "/srv/agent-canvas/beta/state";
                    };
                  };
                };
              }
            ];
          }).config.containers."agent-canvas-beta".config.system.build.toplevel;
      };
    };
}
