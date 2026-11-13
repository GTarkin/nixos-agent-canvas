# Gast-Seite: NixOS-System für den nspawn-Container, in dem Agent Canvas läuft.
#
# Der Wirt (siehe host.nix) startet diesen Closure als Container mit
# ephemeralem Root (tmpfs) und hängt zwei Verzeichnisse herein:
#   /projects                      -> Workspace, den der Agent bearbeitet
#   /home/openhands/.openhands     -> Settings, Conversations, Caches
#
# Alles andere im Gast ist bei einem Neustart weg — das ist Absicht. Der Agent
# läuft als uid 10001 (User `openhands`) und holt Werkzeuge über Nix
# (`nix shell nixpkgs#jq`, `nix profile install …`); der Wirt teilt dafür
# seinen Store (read-only) und den nix-daemon-Socket.
#
# WARUM NICHT ROOT: der nix-Daemon läuft auf dem WIRT und beurteilt Clients
# nur nach ihrer uid. Gast-Root ist ohne Userns-Remapping Host-Root und damit
# in `trusted-users` -> `Trusted: 1`; ein vertrauenswürdiger Client darf
# daemonweite Optionen setzen (`--option sandbox-paths …`, `post-build-hook`),
# und die führt der Daemon als Host-Root AUSHALB der Container-Isolation aus.
# Das ist ein Ausbruchspfad (Auslöser: Prompt-Injection in einem Upload).
# Als uid 10001 ist der Client unprivilegiert: bauen und Pfade realisieren ja,
# daemonweite Optionen nein. Abnahmekriterium: `nix store info` -> `Trusted: 0`
# (siehe Unit agent-canvas-trust-check).
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

    privateNetwork = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        true, wenn der Gast eine eigene Netzwerk-Namespace hat (Wirt:
        `privateNetwork`). Nur dann darf er seine eigene Firewall verwalten —
        im geteilten Netns würde er die Regeln des WIRTS überschreiben, weil
        iptables/nftables pro Namespace gelten.
      '';
    };

    litellmHost = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Adresse, unter der das LiteLLM-Gateway aus dem Gast erreichbar ist.
        Geteilter Netns: 127.0.0.1. Eigenes veth: die Host-Seite (hostAddress).
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
      # KEIN `trusted-users` hier: bei `store = "daemon"` entscheidet der
      # Daemon des WIRTS anhand der Peer-uid, nicht diese Datei. Die Option
      # wäre also wirkungslos und würde nur suggerieren, man könnte den Trust
      # im Gast konfigurieren.
      # Global in /etc/nix/nix.conf: der lokale Store ist read-only gebunden,
      # Schreibzugriffe müssen über den Daemon des Wirts laufen. Als
      # environment.variables reicht es nicht (greift nur in Login-Shells).
      store = "daemon";
    };

    # Fällt für alles zurück, was doch als generisches Linux-Binary kommt
    # (der Agent lädt gern mal Fremd-Binaries). Ohne das: "NixOS cannot run
    # dynamically linked executables intended for generic linux environments".
    programs.nix-ld.enable = true;

    # LiteLLM läuft im Host-Netz (0.0.0.0:4000). Der Name kommt aus dem
    # LLM-Profil (Preset) und muss im Gast auflösen: ohne eigenes veth ist das
    # 127.0.0.1 (geteilter Netns), mit veth die Host-Seite (litellmHost).
    networking.extraHosts = "${cfg.litellmHost} litellm";

    # NixOS-Container: Store und nix-daemon kommen vom Wirt.
    boot.isContainer = true;

    # Kein IPv6 im Gast: erreichbar ist er nur über veth-IPv4 (und litellm per
    # extraHosts). Die automatische Link-Local-Adresse auf eth0 wäre ein
    # lateraler Pfad, sobald je ein weiterer Container im selben Segment steht;
    # disable_ipv6 entfernt sie auch von der bereits existierenden Schnittstelle.
    networking.enableIPv6 = false;
    boot.kernel.sysctl."net.ipv6.conf.eth0.disable_ipv6" = true;

    # Eigene Firewall NUR mit eigener Netzwerk-Namespace. Im geteilten Netns
    # würde der Gast die Regeln des WIRTS überschreiben (iptables/nftables
    # gelten pro Namespace) — deshalb war sie hier abgeschaltet. Die
    # Portweiterleitung 10.100.x.1 -> 10.100.x.2 macht der Wirt (veth).
    networking.firewall.enable = cfg.privateNetwork;
    networking.firewall.allowedTCPPorts = lib.optionals cfg.privateNetwork [ cfg.port ];
    # Statische Adresse setzt der Container-Init des Wirts; DHCP gibt es nicht.
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

    # Dienst-User im Gast. Die uid MUSS der des Host-Users `openhands` aus
    # nixos-config entsprechen: ohne Userns-Remapping werden Bind-Mounts 1:1
    # gemappt, sonst kann der Gast die Dateien auf dem Wirt nicht schreiben.
    users.groups.openhands.gid = 10001;
    users.users.openhands = {
      isSystemUser = true;
      uid = 10001;
      group = "openhands";
      home = "/home/openhands";
    };

    # NUR /home/openhands anlegen. Die beiden anderen Pfade sind vom Wirt
    # hereingebundene Mountpoints: eine tmpfiles-Regel darauf wirkt auf der
    # HOST-Seite und hat dort schon einmal die Rechte zerlegt (`/projects`
    # wurde 0755 root root, die ACL-Maske fiel auf `---`). Besitzer und Modus
    # gehören deshalb dem Wirt, nicht dem Gast.
    systemd.tmpfiles.rules = [
      "d /home/openhands 0750 openhands openhands -"
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
        # `nix profile install` legt sein Profil unter $XDG_STATE_HOME ab, der
        # Fetcher (nixpkgs-Tarball, Eval-Cache) unter $XDG_CACHE_HOME. Beides
        # in den State-Bind, sonst ist das Profil nach jedem Neustart weg und
        # nixpkgs wird erneut geladen.
        XDG_STATE_HOME = "${cfg.stateDir}/xdg-state";
        XDG_CACHE_HOME = "${cfg.stateDir}/xdg-cache";
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
        # Der Dienst läuft unprivilegiert (siehe Kopfkommentar): `nix shell`
        # und `nix profile install` gehen als normaler Nutzer, aber der
        # Daemon des Wirts stuft ihn nicht als vertrauenswürdig ein. Die
        # EnvironmentFile liest systemd weiterhin als root ein, die Datei
        # bleibt daher 0400 root auf dem Wirt.
        User = "openhands";
        Group = "openhands";
        WorkingDirectory = "/home/openhands";
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
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

    # Regressionstest für die Trust-Grenze: fällt der Dienst je wieder auf root
    # zurück (oder wird der Daemon des Wirts anders konfiguriert), ist der
    # Agent wieder vertrauenswürdig — und damit ein Host-Root-Ausbruchspfad.
    # Blockiert den Start nicht, wird aber in `systemctl status` rot.
    systemd.services.agent-canvas-trust-check = {
      description = "Prüft, dass der Agent gegenüber dem nix-Daemon unprivilegiert ist";
      wantedBy = [ "multi-user.target" ];
      after = [ "agent-canvas.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "openhands";
        Group = "openhands";
      };
      script = ''
        out=$(${pkgs.nix}/bin/nix store info 2>&1)
        case "$out" in
          *"Trusted: 0"*) echo "ok: nix-Daemon behandelt den Agenten als unprivilegiert" ;;
          *)
            echo "FEHLER: der Dienst gilt für den nix-Daemon als privilegiert:"
            echo "$out"
            exit 1
            ;;
        esac
      '';
    };
  };
}
