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
- **Userns + eigenes Netz je Gast.** `privateUsers` = 300000/400000 (Quelle:
  `hosts/vps-server/agent-canvas-ids.nix` im Wirts-Repo). Host-Owner der Binds
  ist `Basis+10001`, `secrets.env` gehört `Basis` (Gast-Root liest die
  EnvironmentFile). Binds bleiben ohne `idmap` — mit `idmap` sähe Gast-Root
  wieder Host-Root.
  `privateNetwork = true` mit eigenem veth: im geteilten Netns erreicht der
  Agent die Host-Loopback-Dienste (Postgres, SFTPGo-Admin, Django,
  oauth2-proxy) und die andere Instanz. Auf dem Wirt deshalb 22/80/443 nur auf
  `ens6` freigeben, LiteLLM (4000) als einzige Ausnahme für 10.100.0.0/16,
  NAT für den Container-Egress.
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
- `privateUsers` ist umgesetzt (300000/400000). Offen bleibt die Härtung
  gegen *verschachtelte* Userns (der Agent darf `unshare -r`; Podman auf dem
  Wirt braucht unprivilegierte Userns, also kein globales Abschalten):
  `user.max_user_namespaces` oder ein seccomp-Profil — separates Ticket.
- Beim Wechsel auf dem Wirt: die bestehenden Podman-Container bleiben, bis der
  Gast auf einem Testport bewiesen ist.
