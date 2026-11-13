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

  # Python samt Zusatzpaketen (pandas & Co.). Landet im PATH der Unit, damit
  # der Agent im Tool-Shell genau diesen Interpreter vorfindet.
  pythonEnv = pkgs.python314.withPackages (
    _:
    if builtins.isFunction cfg.pythonPackages then
      cfg.pythonPackages pkgs.python314Packages
    else
      cfg.pythonPackages
  );
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

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = ''
        Zusätzliche Pakete für diesen Gast: landen in environment.systemPackages
        und im PATH der Unit (nur systemPackages reicht dem Agenten nicht).
      '';
    };

    pythonPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "with pkgs.python314Packages; [ pandas openpyxl ]";
      description = "Python-Pakete des Interpreters, den der Agent benutzt.";
    };

    portOffset = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = ''
        Verschiebt die internen Ports (agent-server 18000, automation 18001,
        vscode 18003, vite 18005) um diesen Betrag. Nötig, wenn mehrere Gäste
        den Netzwerk-Namespace des Wirts teilen — sonst kollidieren sie.
      '';
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
    # Der Agent soll `nix shell nixpkgs#tool` und `nix profile install` nutzen.
    # Flakes müssen dafür aktiv sein, und der Client schreibt über den
    # Daemon des Wirts (der Store im Gast ist read-only gebunden).
    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [ "root" ];
      # Global in /etc/nix/nix.conf: der lokale Store ist read-only gebunden,
      # Schreibzugriffe müssen über den Daemon des Wirts laufen. Als
      # environment.variables reicht es nicht (greift nur in Login-Shells).
      store = "daemon";
    };

    # Fällt für alles zurück, was doch als generisches Linux-Binary kommt
    # (der Agent lädt gern mal Fremd-Binaries). Ohne das: "NixOS cannot run
    # dynamically linked executables intended for generic linux environments".
    programs.nix-ld.enable = true;

    # LiteLLM läuft im Host-Netz (0.0.0.0:4000); der Gast teilt diesen
    # Namespace, also ist 127.0.0.1 richtig. Der Name kommt aus dem
    # LLM-Profil (Preset) und muss auch im Gast auflösen.
    networking.extraHosts = "127.0.0.1 litellm";

    # NixOS-Container: Store und nix-daemon kommen vom Wirt.
    boot.isContainer = true;

    # Im Container gibt es keine eigene Firewall; die Portweiterleitung macht
    # der Wirt (forwardPorts).
    networking.firewall.enable = false;
    networking.useDHCP = false;

    system.stateVersion = "25.11";

    # bash/coreutils sind nicht optional: npm und uv spawnen `sh` für
    # Lifecycle-Skripte, und NixOS setzt den PATH der Unit nur aus diesen
    # Paketen zusammen (/bin/sh allein hilft nicht, es steht nicht im PATH).
    environment.systemPackages =
      with pkgs;
      [
        bash
        coreutils
        nodejs_24
        uv
        git
        curl
        jq
        ripgrep
        gnutar
        gzip
        which
        cacert
      ]
      ++ cfg.extraPackages
      # pythonEnv stellt `python3` (mit den Zusatzpaketen) — deshalb steht das
      # nackte python314 bewusst nicht in dieser Liste.
      ++ [ pythonEnv ];

    # BEWUSST KEIN tmux im PATH: das Terminal-Werkzeug nutzt tmux nur, wenn es
    # eines findet, sonst den robusteren subprocess-Backend. Mit tmux 3.8
    # stirbt der Server, sobald die letzte Session weg ist (exit-empty), und
    # libtmux arbeitet danach mit veralteten Fenster-IDs
    # ("list-panes: can't find window: @N"). Nicht wieder einbauen, ohne das
    # gegen eine echte Conversation zu testen.

    # Der Agent darf im gesamten Gast schreiben (root), aber nur diese zwei
    # Pfade überleben einen Neustart.
    systemd.tmpfiles.rules = [
      "d /home/openhands 0700 root root -"
      "d ${cfg.stateDir} 0700 root root -"
      "d ${cfg.workspaceDir} 0755 root root -"
    ];

    systemd.services.agent-canvas = {
      description = "OpenHands Agent Canvas";

      # WICHTIG: environment.systemPackages landet NICHT im PATH einer Unit.
      # Ohne diese Liste findet npm kein `sh` und keine Tools (erster Versuch:
      # "npm error enoent spawn sh").
      path = [
        pythonEnv
      ]
      ++ cfg.extraPackages
      ++ (with pkgs; [
        bash
        coreutils
        nodejs_24
        uv
        git
        gnutar
        gzip
        which
        cacert
        # Damit der Agent selbst Werkzeuge holen kann (nix shell/profile);
        # ohne diesen Eintrag findet der Tool-Shell kein `nix`.
        nix
      ]);
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
        # Interne Ports pro Instanz verschieben (geteilter Netns!).
        OH_CANVAS_SAFE_BACKEND_PORT = toString (18000 + cfg.portOffset);
        OH_CANVAS_SAFE_AUTOMATION_PORT = toString (18001 + cfg.portOffset);
        OH_CANVAS_SAFE_VSCODE_PORT = toString (18003 + cfg.portOffset);
        OH_CANVAS_SAFE_VITE_PORT = toString (18005 + cfg.portOffset);
        # Nix-Python statt uv-Download (generisches glibc-CPython laeuft hier
        # nicht) und Loader-Pfad fuer PyPI-Wheels (tokenizers -> libstdc++).
        UV_PYTHON_PREFERENCE = "only-system";
        LD_LIBRARY_PATH = lib.makeLibraryPath [
          pkgs.stdenv.cc.cc.lib
          pkgs.zlib
        ];
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
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
