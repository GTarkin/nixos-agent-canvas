# Wirt-Seite: startet NixOS-Gäste als systemd-nspawn-Container.
#
# Das Modul erzeugt pro Instanz einen Container mit:
#   * ephemeralem Root (tmpfs) — was der Agent außerhalb der Binds ändert, ist
#     beim nächsten Start weg
#   * geteiltem Store (macht das NixOS-Containermodul automatisch, read-only)
#   * zwei Bind-Mounts: Workspace und State
#   * mit privateNetwork = true ein eigenes veth; sonst teilt der Gast den
#     Netzwerk-Namespace des Wirts (dann erreicht er dessen Loopback!)
#
# Beispiel:
#   services.agent-canvas-host.instances.gtarkin = {
#     privateNetwork = true;
#     hostAddress = "10.100.1.1";
#     localAddress = "10.100.1.2";
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
                type = lib.types.nullOr lib.types.port;
                default = null;
                description = ''
                  Nur bei privateNetwork = true: nspawn-DNAT von diesem Host-Port
                  auf containerPort. Vorsicht: DNAT läuft über FORWARD, nicht
                  INPUT — der Port ist damit nicht durch die nixos-fw-Regeln
                  geschützt. Für Produktion besser ohne forwardPorts arbeiten und
                  nginx direkt auf die Container-IP zeigen lassen.
                '';
              };

              privateNetwork = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                  false: Container teilt den Netzwerk-Namespace des Wirts — die
                  Dienste im Gast belegen Host-Ports direkt und erreichen die
                  Host-Loopback-Dienste (Postgres, Admin-Oberflächen, andere
                  Instanzen). Nur für einen einzelnen Testgast vertretbar.
                  true: eigenes veth; dann hostAddress/localAddress setzen und
                  nginx auf die Container-Adresse zeigen lassen.
                '';
              };

              hostAddress = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                example = "10.100.1.1/24";
                description = "Host-Seite des veth (nur bei privateNetwork = true).";
              };

              localAddress = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                example = "10.100.1.2";
                description = "Container-Adresse; im Gast als statische IP setzen.";
              };

              privateUsers = lib.mkOption {
                type = lib.types.either lib.types.ints.u32 (
                  lib.types.enum [
                    "no"
                    "identity"
                  ]
                );
                default = "no";
                description = ''
                  Userns-Basis (systemd-nspawn --private-users). Bei einer Zahl
                  gilt: Gast-uid `z` == Host-uid `Basis + z`. Dann müssen
                  workspaceDir und stateDir der Host-uid `Basis + <Dienst-uid>`
                  gehören (guest.nix: 10001) und secretsFile der uid `Basis`
                  (Gast-Root liest die EnvironmentFile). Die Basis darf nicht
                  mit /etc/subuid (rootless Podman) überlappen.

                  Achtung: `identity` isoliert nur Capabilities, nicht die uids —
                  Gast-Root bleibt Host-Root. Für den Trust gegenüber dem
                  nix-Daemon zählt ausschließlich eine echte Zahlen-Basis.
                '';
              };

              workspaceDir = lib.mkOption {
                type = lib.types.str;
                example = "/srv/openhands/gtarkin/projects";
                description = ''
                  Host-Pfad, der im Gast als /projects erscheint. Muss dem
                  Dienst-User des Gasts gehören — ohne Userns uid 10001, mit
                  privateUsers = Basis die uid Basis+10001.
                '';
              };

              stateDir = lib.mkOption {
                type = lib.types.str;
                example = "/srv/openhands/gtarkin/state";
                description = ''
                  Host-Pfad für Settings/Conversations (~/.openhands im Gast).
                  Muss existieren und dem Dienst-User des Gasts gehören
                  (ohne Userns 10001, mit Basis Basis+10001) — NICHT root. Der
                  Gast setzt darauf bewusst keine tmpfiles-Regel, weil die Regel
                  auf einen Bind-Mountpoint wirkt und damit die Rechte auf dem
                  Wirt überschreibt.
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
                  Mit privateUsers muss die Datei der uid `Basis` gehören
                  (Gast-Root liest sie) und 0400 bleiben — Host-Root ist für den
                  Gast „nobody" und kommt per DAC-Override nicht heran.
                '';
              };

              portOffset = lib.mkOption {
                type = lib.types.int;
                default = 0;
                description = "Verschiebt die internen Ports im Gast (geteilter Netns: pro Instanz verschieden).";
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
    assertions = lib.mapAttrsToList (name: inst: {
      assertion = !inst.privateNetwork || (inst.hostAddress != null && inst.localAddress != null);
      message = "services.agent-canvas-host.instances.${name}: privateNetwork = true braucht hostAddress und localAddress.";
    }) cfg.instances;

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
                  inherit (inst) port portOffset privateNetwork;
                  # Der Name `litellm` muss im eigenen Netns auf die Host-Seite
                  # des veth zeigen; im geteilten Netns bleibt es 127.0.0.1.
                  litellmHost =
                    if inst.privateNetwork && inst.hostAddress != null then
                      lib.head (lib.splitString "/" inst.hostAddress)
                    else
                      "127.0.0.1";
                  environmentFile = lib.mkIf (inst.secretsFile != null) "/run/agent-canvas.env";
                };
              }
              inst.extraConfig
            ];
          };

        # Binds bleiben bewusst OHNE idmap (nspawn-Default `noidmap`): damit
        # gilt Gast-uid z == Host-uid Basis+z. Mit `idmap` sähe Gast-Root auf
        # diesen Mounts wieder Host-Root — genau die Rechte, die wir vermeiden.
        # Ohne Userns (privateUsers = "no") ist Basis 0, also Gast-uid == Host-uid.
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

        inherit (inst) privateNetwork privateUsers;

        forwardPorts = lib.optionals (inst.privateNetwork && inst.hostPort != null) [
          {
            containerPort = inst.port;
            hostPort = inst.hostPort;
            protocol = "tcp";
          }
        ];

        inherit (inst) hostAddress localAddress;
      }
    ) cfg.instances;
  };
}
