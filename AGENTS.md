# AGENTS.md

Konventionen für dieses Repo (analog zu `nixos-config`, aber kleiner).

## Was das hier ist

Agent Canvas als NixOS-Gast im nspawn-Container. **Kein OCI-Image** — der
NixOS-System-Closure im Store *ist* das Artefakt. Es gibt deshalb keinen
Image-Digest zu pinnen; Versionen kommen aus `flake.lock`.

## Harte Randbedingungen

- **Root im Gast ist Absicht** (uid 0 im Container). Der Agent soll
  `nix shell`/`nix profile install` nutzen können. Isolation kommt vom
  nspawn-Container, nicht von einer UID im Gast. Nicht „aus Sicherheitsgründen"
  auf einen normalen User umstellen, ohne das mit dem Wirt neu zu bewerten.
- **`ephemeral = true`** in `nixos/modules/host.nix`: alles außerhalb der Binds
  ist bei Neustart weg. Wer Zustand braucht, muss ihn binden — nicht das
  Overlay abschalten.
- **Der Store gehört dem Wirt.** Der Gast kann Pfade hinzufügen (über den
  nix-daemon-Socket) und sieht alle Store-Pfade. Er kann damit keinen Host-Root
  erlangen, aber CPU/Disk verbrauchen.
- **Persistenz nur über die zwei Binds** (`/projects`, `~/.openhands`).

## Aufbau

| Datei | Rolle |
|---|---|
| `nixos/modules/guest.nix` | Gast-System: Optionen unter `services.agent-canvas`, tmpfiles, Service als root |
| `nixos/modules/host.nix` | Wirt: `services.agent-canvas-host.instances.<name>` → `containers."agent-canvas-<name>"` |
| `pkgs/agent-canvas/` | WIP-Paketierung, bewusst nicht im Flake exportiert (siehe Kopfkommentar) |
| `tests/flake.nix` | eigener Flake, prüft die Nutzung als Flake-Input |

## Befehle

```bash
nix flake check                 # muss grün sein, bevor etwas committet wird
nix flake check ./tests         # prüft die Nutzung als Flake-Input
nix build .#checks.x86_64-linux.guest
nix fmt                         # nixfmt-rfc-style
```

## Stil

- Deutsch in Kommentaren, Englisch in Optionsnamen/Doku-Strings (wie in
  `nixos-config`).
- Kommentare erklären **warum**, nicht was.
- Jede Verhaltensänderung an `ephemeral`, Binds oder Rechten im Gast ist eine
  Änderung am Sicherheitsmodell → im Commit begründen.

## Fallen, die schon zugeschlagen haben

- `environment.systemPackages` ≠ Unit-PATH → `systemd.services.agent-canvas.path`.
- uv lädt ohne `UV_PYTHON_PREFERENCE=only-system` ein generisches glibc-Python,
  das im Gast nicht startet (stub-ld).
- `NIX_REMOTE` per `environment.variables` wirkt nur in Login-Shells;
  `nix.settings.store = "daemon"` wirkt global (nötig, weil der Store
  read-only gebunden ist).

## Offene Punkte

- `pkgs/agent-canvas` fertigstellen (Lockfile-Problem → GitHub-Quelle).
- `privateUsers` erst nach bewiesenem Betrieb.
- Beim Wechsel auf dem Wirt: die bestehenden Podman-Container bleiben, bis der
  Gast auf einem Testport bewiesen ist.
