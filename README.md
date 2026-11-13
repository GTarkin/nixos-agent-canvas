# nixos-agent-canvas

Agent Canvas (OpenHands) als **NixOS-Gast in einem systemd-nspawn-Container** —
statt als Debian-OCI-Image. Der Agent läuft als uid 10001 (`openhands`) im Gast
und holt Werkzeuge über Nix (`nix shell nixpkgs#jq`, `nix profile install …`),
während der Wirt nur seinen Store teilt und zwei Verzeichnisse hereinhängt.
Unprivilegiert ist dabei nicht Kosmetik: als root wäre der Gast für den
nix-Daemon des Wirts vertrauenswürdig und könnte darüber Host-Root erlangen.
Zusätzlich läuft jeder Gast in einer eigenen Userns (`privateUsers`) und einem
eigenen Netzwerk-Namespace (`privateNetwork`, eigenes veth).

## Warum

Das offizielle Image ist Debian, bringt `apt` mit (nutzlos, weil der Agent als
UID 10001 ohne Rechte läuft) und jede Installation wäre beim nächsten
Container-Start weg. Ein NixOS-Gast löst beides:

| | offizielles Image | dieser Gast |
|---|---|---|
| Werkzeuge | `apt`, flüchtig, kein root | `nix shell` / `nix profile`, deklarativ, überlebt |
| Store | pro Container dupliziert | geteilt vom Wirt (read-only Bind) |
| Root-Dateisystem | schreibbar, driftet | tmpfs (`ephemeral`), bei Neustart weg |
| Updates | Image-Digest pinnen | `flake.lock` |

## Aufbau

```
flake.nix                     nixosConfigurations.agent-canvas-guest, nixosModules.{guest,host}, checks
nixos/modules/guest.nix       Gast: systemd-Service `agent-canvas`, node+uv, /projects
nixos/modules/host.nix        Wirt: containers.<name> (ephemeral, Bind-Mounts, forwardPorts)
pkgs/agent-canvas/            WIP: vollständiges Nix-Paket (siehe Kopfkommentar dort)
tests/flake.nix               eigener Flake: prüft Nutzung als Flake-Input
```

### Persistenz

Im Gast überlebt **nur**, was der Wirt bindet:

| Gast-Pfad | Host-Pfad | Inhalt |
|---|---|---|
| `/projects` | `/srv/openhands/<instanz>/projects` | Workspace des Agenten |
| `/home/openhands/.openhands` | `/srv/openhands/<instanz>/state` | Settings, Conversations, uv-/npm-Caches, `nix profile` (`XDG_STATE_HOME`) |

Alles andere (inkl. `/home/openhands/workspace`) ist tmpfs. `XDG_CACHE_HOME`
zeigt ebenfalls in den State-Bind, damit nixpkgs nach einem Neustart nicht
erneut geladen wird.

### Userns und Netz

| | Wert | Konsequenz |
|---|---|---|
| `privateUsers` | 300000 / 400000 (je Instanz) | Gast-uid `z` = Host-uid `Basis+z`; Host-Owner der Binds ist `Basis+10001`, `secrets.env` gehört `Basis` |
| `privateNetwork` | `true`, veth `10.100.<n>.1` (Host) / `.2` (Gast) | kein Zugriff auf die Host-Loopback-Dienste; nginx proxyt auf die Container-Adresse |
| LiteLLM | `http://litellm:4000` → Host-Seite des veth | einzige Host-Ausnahme in der Firewall (`10.100.0.0/16` → 4000) |

Binds bewusst **ohne** `:idmap`: mit `idmap` sähe Gast-Root auf `/projects` und
im State wieder Host-Root. `noidmap` (Default) macht Gast-Root dort zu
„nobody" — genau richtig.

## Benutzung auf dem Wirt

```nix
{
  inputs.agent-canvas.url = "github:GTarkin/nixos-agent-canvas";

  # im Host-Modul
  imports = [ inputs.agent-canvas.nixosModules.host ];

  services.agent-canvas-host = {
    enable = true;
    instances.gtarkin = {
      hostPort = 8001;                     # 127.0.0.1, davor nginx/oauth2-proxy
      workspaceDir = "/srv/openhands/gtarkin/projects";
      stateDir = "/srv/openhands/gtarkin/state";
    };
  };
}
```

Verzeichnisse vorher anlegen und dem Dienst-User (uid 10001) übergeben — der
Gast setzt darauf bewusst keine tmpfiles-Regel, weil die auf der Host-Seite
wirken würde:

```nix
systemd.tmpfiles.rules = [
  "d /srv/openhands/gtarkin/projects 0775 openhands openhands -"
  "d /srv/openhands/gtarkin/state    0700 openhands openhands -"
];
```

## Entwickeln

```bash
nix flake check                 # Gast baut, Host-Modul evaluiert
nix build .#checks.x86_64-linux.guest
nix develop                     # nodejs_24, uv, nixfmt
```

## Verifiziert (2026-11-13, Testgast auf der VPS)

| Prüfung | Ergebnis |
|---|---|
| Gast bootet aus dem Store (kein Image) | `machinectl list` → `agent-canvas-test`, `/canvas` → 200 |
| Ephemerer Root | `touch /root/marker` → nach Restart weg |
| Persistenz der Binds | `~/.openhands` (Settings, npm-/uv-Cache) und `/projects` bleiben |
| Store geteilt | `nix shell nixpkgs#jq` holt nur `jq` in den Host-Store, Daemon-Socket funktioniert |
| Profil überlebt Restart | `nix profile install nixpkgs#ripgrep` ist nach Container-Neustart noch da (`XDG_STATE_HOME` liegt im State-Bind) |
| Agent unprivilegiert | `nix store info` → `Trusted: 0` (Unit `agent-canvas-trust-check`); `nix shell`/`nix profile install` funktionieren trotzdem |
| Eigene Userns | `cat /proc/1/uid_map` → `0 300000 65536`, `id` → `10001`; Host-Owner der Dateien ist `310001` |
| Eigenes Netz | `readlink /proc/self/ns/net` ≠ Host; Host-Loopback (5432, 8081, 28981 …) nicht erreichbar; LiteLLM auf 4000 weiterhin |
| Wirt unberührt | bestehende Podman-Container laufen während aller Deploys weiter |

## Stolpersteine (schon eingebaut)

- **`environment.systemPackages` landet nicht im PATH einer Unit.** npm braucht
  `sh` → `systemd.services.agent-canvas.path` explizit setzen.
- **Generisches glibc-Python läuft nicht** (stub-ld): `python314` + `UV_PYTHON_PREFERENCE=only-system`, plus `programs.nix-ld` als Fallback.
- **`NIX_REMOTE` aus `/etc/set-environment` greift nur in Login-Shells**: der
  Store im Gast ist read-only gebunden, deshalb `nix.settings.store = "daemon"`.

## Stand / Nächstes

- [x] Gast-Modul mit Service, Store-Zugriff, Persistenz-Binds
- [x] Wirt-Modul mit ephemeral-Containern und Portweiterleitung
- [x] Checks (Gast baut, Host-Modul erzeugt Container)
- [x] Userns-Remapping (`privateUsers`) und eigenes veth (`privateNetwork`)
- [ ] `pkgs/agent-canvas`: npm-Paket hat kein Lockfile → Quelle wird das
      GitHub-Repo (`OpenHands/OpenHands`, `npmBuildScript = "build:app"`),
      Details im Kopfkommentar der Datei
- [ ] optional `tests/`: echter VM-Test, der den Dienst startet (bisher nur
      Build-/Evaluations-Checks)

## Lizenz

MIT
