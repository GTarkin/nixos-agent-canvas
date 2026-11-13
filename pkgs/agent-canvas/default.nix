# WIP — bewusst NICHT in flake.nix exportiert.
#
# Ziel: agent-canvas vollständig paketieren, damit der Gast nicht beim ersten
# Start per npx ins Netz muss.
#
# Blocker (Stand 2026-11-13): `npm publish` legt kein package-lock.json ins
# Tarball, `buildNpmPackage` verlangt aber eines. Deshalb ist die Quelle das
# GitHub-Repo (OpenHands/OpenHands), das eine package-lock.json im Root hat:
#
#   src = fetchFromGitHub {
#     owner = "OpenHands"; repo = "OpenHands";
#     rev = "v<VERSION>"; hash = lib.fakeHash;
#   };
#   npmDepsHash = lib.fakeHash;          # aus dem Build-Fehler übernehmen
#   npmBuildScript = "build:app";        # react-router build -> build/
#   postInstall = ''
#     mkdir -p $out/lib/agent-canvas $out/bin
#     cp -r build $out/lib/agent-canvas/frontend   # Launcher erwartet ./frontend
#     cp -r bin $out/lib/agent-canvas/bin
#     makeWrapper ${nodejs_24}/bin/node $out/bin/agent-canvas \
#       --add-flags $out/lib/agent-canvas/bin/agent-canvas.mjs
#   '';
#
# Zu prüfen: ob der Launcher `frontend/` relativ zu __dirname auflöst (im
# offiziellen Image: /opt/agent-canvas/frontend, Log "Static dir: …").
{
  lib,
  buildNpmPackage,
  fetchurl,
  nodejs_24,
}:

buildNpmPackage rec {
  pname = "agent-canvas";
  version = "1.40.0";

  # Platzhalter: siehe Kopfkommentar (npm-Tarball als Zwischenlösung).
  src = fetchurl {
    url = "https://registry.npmjs.org/@openhands/agent-canvas/-/agent-canvas-${version}.tgz";
    hash = "sha256-GHc/iR4TYvEqVR88sCI2oB3VJwHObpX1JqItKmLOiyw=";
  };

  npmDepsHash = lib.fakeHash;
  nodejs = nodejs_24;
  dontNpmBuild = true;
  sourceRoot = "package";

  meta = with lib; {
    description = "OpenHands Agent Canvas (UI + Launcher)";
    homepage = "https://github.com/OpenHands/OpenHands";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "agent-canvas";
  };
}
