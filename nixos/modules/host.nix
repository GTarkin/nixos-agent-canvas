# Wirt-Seite: startet NixOS-Gäste als systemd-nspawn-Container.
#
# Das Modul erzeugt pro Instanz einen Container mit:
#   * ephemeralem Root (tmpfs) — was der Agent außerhalb der Binds ändert, ist
#     beim nächsten Start weg
#   * geteiltem Store (macht das NixOS-Containermodul automatisch, read-only)
#   * zwei Bind-Mounts: Workspace und State
#   * Portweiterleitung Gast -> 127.0.0.1 (davor oauth2-proxy/nginx)
#
# Beispiel:
#   services.agent-canvas-host.instances.gtarkin = {
#     hostPort = 8001;
#     workspaceDir = "/srv/openhands/gtarkin/projects";
#     stateDir = "/srv/openhands/gtarkin/state";
#   };
{ config, lib, ... }:

let
  cfg = config.services.agent-canvas-host;
in
{
  options.services.agent-canvas-host = {
    enable = lib.mkEnableOption "Agent Canvas nspawn guests";

    instances = lib.mkOption {
      default = { };
      description = "Agent-Canvas-Instanzen, je ein nspawn-Container.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              port = lib.mkOption {
                type = lib.types.port;
                default = 8000;
                description = "Port im Gast.";
              };

              hostPort = lib.mkOption {
                type = lib.types.port;
                description = "Port auf 127.0.0.1 des Wirts (nginx/oauth2-proxy davor).";
              };

              workspaceDir = lib.mkOption {
                type = lib.types.str;
                example = "/srv/openhands/gtarkin/projects";
                description = "Host-Pfad, der im Gast als /projects erscheint.";
              };

              stateDir = lib.mkOption {
                type = lib.types.str;
                example = "/srv/openhands/gtarkin/state";
                description = ''
                  Host-Pfad für Settings/Conversations (~/.openhands im Gast).
                  Muss existieren und dem Gast-root gehören (rootful nspawn).
                '';
              };

              secretsFile = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                example = "/srv/agent-canvas/gtarkin/secrets.env";
                description = ''
                  Host-Datei mit LOCAL_BACKEND_API_KEY / OH_SECRET_KEY. Wird
                  read-only nach /run/agent-canvas.env gebunden und im Gast als
                  EnvironmentFile genutzt. Inhalt kommt aus sops (Host-Oneshot).
                '';
              };

              memoryMax = lib.mkOption {
                type = lib.types.str;
                default = "2G";
                description = "Speicherlimit der Container-Unit (nspawn).";
              };

              # Freie Zusatzmodul für den Gast (z. B. Version, Paket, Env).
              extraConfig = lib.mkOption {
                type = lib.types.deferredModule;
                default = { };
                description = "Zusätzliche Konfiguration für den Gast-NixOS.";
              };
            };
          }
        )
      );
    };
  };

  config = lib.mkIf (cfg.enable && cfg.instances != { }) {
    # nspawn-Gast ohne Limit wäre der einzige Prozess auf der Kiste ohne Deckel.
    systemd.services = lib.mapAttrs' (
      name: inst:
      lib.nameValuePair "container@agent-canvas-${name}" {
        serviceConfig.MemoryMax = inst.memoryMax;
      }
    ) cfg.instances;

    containers = lib.mapAttrs' (
      name: inst:
      lib.nameValuePair "agent-canvas-${name}" {
        # Root als tmpfs: Agent-Änderungen außerhalb der Binds verschwinden.
        ephemeral = true;
        autoStart = true;

        config =
          { ... }:
          {
            imports = [
              ../modules/guest.nix
              {
                services.agent-canvas = {
                  enable = true;
                  port = inst.port;
                };
              }
              inst.extraConfig
            ];
          };

        bindMounts = lib.mkMerge [
          (lib.mkIf (inst.secretsFile != null) {
            "/run/agent-canvas.env" = {
              hostPath = inst.secretsFile;
              isReadOnly = true;
            };
          })
          {
            "/projects" = {
              hostPath = inst.workspaceDir;
              isReadOnly = false;
            };
            "/home/openhands/.openhands" = {
              hostPath = inst.stateDir;
              isReadOnly = false;
            };
          }
        ];

        # nspawn bindet --port auf 0.0.0.0; nach außen bleibt es zu, weil die
        # Ports nicht in networking.firewall.allowedTCPPorts stehen.
        forwardPorts = [
          {
            containerPort = inst.port;
            hostPort = inst.hostPort;
            protocol = "tcp";
          }
        ];
      }
    ) cfg.instances;
  };
}
