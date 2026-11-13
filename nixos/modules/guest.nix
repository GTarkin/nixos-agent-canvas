# Gast-Seite: NixOS-System für den nspawn-Container, in dem Agent Canvas läuft.
#
# Der Wirt (siehe host.nix) startet diesen Closure als Container mit
# ephemeralem Root (tmpfs) und hängt zwei Verzeichnisse herein:
#   /projects                      -> Workspace, den der Agent bearbeitet
#   /home/openhands/.openhands     -> Settings, Conversations, Caches
#
# Alles andere im Gast ist bei einem Neustart weg — das ist Absicht. Der Agent
# läuft als root im Gast, damit er Werkzeuge über Nix holen kann
# (`nix shell nixpkgs#jq`, `nix profile install …`); der Wirt teilt dafür
# seinen Store (read-only) und den nix-daemon-Socket.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.agent-canvas;
in
{
  options.services.agent-canvas = {
    enable = lib.mkEnableOption "OpenHands Agent Canvas";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8000;
      description = "Port des Agent-Canvas-Ingress im Gast.";
    };

    version = lib.mkOption {
      type = lib.types.str;
      default = "1.40.0";
      description = ''
        Version des npm-Pakets @openhands/agent-canvas. Wird nur genutzt, wenn
        `package` nicht gesetzt ist (dann läuft der Launcher per npx und lädt
        das Paket beim ersten Start in den State-Cache).
      '';
    };

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      example = lib.literalExpression "inputs.self.packages.\${system}.agent-canvas";
      description = ''
        Optional: vorgepackter agent-canvas (pkgs/agent-canvas). Ohne Angabe
        wird `npx @openhands/agent-canvas@<version>` benutzt — einfacher, aber
        der erste Start braucht Netz und der Paket-Cache liegt im State-Bind.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/home/openhands/.openhands";
      description = "Verzeichnis für Settings/Conversations (Bind-Mount vom Wirt).";
    };

    workspaceDir = lib.mkOption {
      type = lib.types.str;
      default = "/projects";
      description = "Arbeitsverzeichnis des Agenten (Bind-Mount vom Wirt).";
    };

    allowLanSessionKey = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Betten den Session-Key in die UI ein, damit Nutzer keinen Backend-Key
        eintippen müssen. Nur vertretbar, wenn davor ein Identity-Proxy steht
        (oauth2-proxy) und der Port nicht öffentlich erreichbar ist.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/agent-canvas.env";
      description = ''
        Datei mit LOCAL_BACKEND_API_KEY und OH_SECRET_KEY. Wird vom Wirt aus
        sops erzeugt und hereingebunden (host.nix: secretsFile).
      '';
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Zusätzliche Umgebungsvariablen für den Dienst.";
    };
  };

  config = lib.mkIf cfg.enable {
    # NixOS-Container: Store und nix-daemon kommen vom Wirt.
    boot.isContainer = true;

    # Im Container gibt es keine eigene Firewall; die Portweiterleitung macht
    # der Wirt (forwardPorts).
    networking.firewall.enable = false;
    networking.useDHCP = false;

    system.stateVersion = "25.11";

    environment.systemPackages = with pkgs; [
      nodejs_24
      uv
      git
      curl
      jq
      ripgrep
      cacert
    ];

    # Der Agent darf im gesamten Gast schreiben (root), aber nur diese zwei
    # Pfade überleben einen Neustart.
    systemd.tmpfiles.rules = [
      "d /home/openhands 0700 root root -"
      "d ${cfg.stateDir} 0700 root root -"
      "d ${cfg.workspaceDir} 0755 root root -"
    ];

    systemd.services.agent-canvas = {
      description = "OpenHands Agent Canvas";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        HOME = "/home/openhands";
        AGENT_CANVAS_DISABLE_TELEMETRY = "1";
        AGENT_CANVAS_ALLOW_LAN_SESSION_KEY = lib.boolToString cfg.allowLanSessionKey;
        # uv lädt Python/venvs zur Laufzeit; ohne diese Pfade wäre alles
        # beim nächsten Neustart erneut zu holen.
        UV_CACHE_DIR = "${cfg.stateDir}/uv/cache";
        UV_PYTHON_INSTALL_DIR = "${cfg.stateDir}/uv/python";
        NPM_CONFIG_CACHE = "${cfg.stateDir}/npm-cache";
        # Damit der Agent Werkzeuge über Nix holen kann.
        NIX_PATH = "nixpkgs=flake:nixpkgs";
      }
      // cfg.extraEnvironment;

      serviceConfig = {
        WorkingDirectory = "/home/openhands";
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
        # Bewusst als root: der Agent soll `nix shell`/`nix profile install`
        # nutzen können. Die Isolation kommt vom nspawn-Container, nicht von
        # einer UID im Gast.
        ExecStart =
          if cfg.package != null then
            "${cfg.package}/bin/agent-canvas --port ${toString cfg.port} --host 0.0.0.0"
          else
            "${pkgs.writeShellScript "agent-canvas-npx" ''
              exec ${pkgs.nodejs_24}/bin/npx --yes \
                @openhands/agent-canvas@${cfg.version} \
                --port ${toString cfg.port} --host 0.0.0.0
            ''}";
        Restart = "on-failure";
        RestartSec = "10";
        TimeoutStartSec = "600";
      };
    };
  };
}
