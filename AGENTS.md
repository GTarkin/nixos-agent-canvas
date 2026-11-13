# AGENTS.md

Konventionen für dieses Repo (analog zu `nixos-config`, aber kleiner).

## Was das hier ist

Agent Canvas als NixOS-Gast im nspawn-Container. **Kein OCI-Image** — der
NixOS-System-Closure im Store *ist* das Artefakt. Es gibt deshalb keinen
Image-Digest zu pinnen; Versionen kommen aus `flake.lock`.

## Harte Randbedingungen

- **Der Dienst läuft als uid 10001 (`openhands`), nicht als root.** Der Agent
  soll `nix shell`/`nix profile install` nutzen können — das geht als normaler
  Nutzer. Root im Gast wäre ein Ausbruchspfad: ohne Userns-Remapping ist
  Gast-Root = Host-Root, der nix-Daemon des Wirts stuft ihn als
  vertrauenswürdig ein (`Trusted: 1`) und führt daemonweite Optionen
  (`--option sandbox-paths`, `post-build-hook`) als Host-Root aus. Nicht auf
  root zurückstellen. Abnahmekriterium: `nix store info` → `Trusted: 0`
  (Unit `agent-canvas-trust-check`).
- **`ephemeral = true`** in `nixos/modules/host.nix`: alles außerhalb der Binds
  ist bei Neustart weg. Wer Zustand braucht, muss ihn binden — nicht das
  Overlay abschalten.
- **Der Store gehört dem Wirt.** Der Gast kann Pfade hinzufügen (über den
  nix-daemon-Socket) und sieht alle Store-Pfade. Als unprivilegierter Client
  kann er damit keinen Host-Root erlangen (content-addressed, kein
  Überschreiben), aber CPU/Disk verbrauchen. Diese Aussage gilt NUR, solange
  der Dienst nicht als root läuft — Root im Gast darf daemonweite Optionen
  setzen und ist damit Host-Root (siehe oben).
- **Persistenz nur über die zwei Binds** (`/projects`, `~/.openhands`).

## Aufbau

| Datei | Rolle |
|---|---|
| `nixos/modules/guest.nix` | Gast-System: Optionen unter `services.agent-canvas`, tmpfiles, Service als uid 10001 (`openhands`) |
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
- `privateUsers` als zweite Härtungsstufe (Ticket): Userns-Remapping
  (`privateUsers = 100000` — feste Basis, nicht `"pick"`, sonst wechseln die
  Owner), dazu idmapped Binds über `extraFlags` (`--bind=…:idmap`), weil das
  NixOS-Modul `bindMounts` nicht idmappt, und `chown` von `secrets.env`,
  `state` und `projects` auf die Subuid-Basis. Aufwand ~½–1 Tag; Nutzen:
  Schutz gegen Bugs im nix-Daemon und Kernel-Escapes. Erst nach Bewährung
  des uid-10001-Betriebs.
- Beim Wechsel auf dem Wirt: die bestehenden Podman-Container bleiben, bis der
  Gast auf einem Testport bewiesen ist.
