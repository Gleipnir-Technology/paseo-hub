{
  description = "paseo-hub: self-hosted automation layer for Paseo daemons";

  inputs = {
    # Pin via flake.lock for reproducibility. nixos-unstable carries recent
    # nodejs_22 and the current buildNpmPackage/fetchNpmDeps machinery.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      # Systems paseo-hub is known to build for. The dependency tree is pure JS
      # (wasm pglite; prebuilt native TS/rollup binaries via optionalDeps), so
      # any nixpkgs-supported linux/darwin system works; keep the common ones.
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          nodejs = pkgs.nodejs_22; # parity with Dockerfile (node:22-slim)

          # Source tree handed to the builder. Everything npm/tsgo/vite needs is
          # included; generated/VCS dirs are excluded so the fixed-output paths
          # stay stable and lean.
          src = builtins.path {
            name = "paseo-hub-source";
            path = ./.;
            filter = path: type:
              let base = baseNameOf path;
              in !(type == "directory" && (
                base == "node_modules" || base == ".git" || base == ".dev" ||
                base == "dist" || base == ".output" || base == ".typecheck" ||
                base == "base" || base == "e2e-report"
              ));
          };

          # `pg@8.20.0` declares an OPTIONAL dependency `pg-hubflare@1.3.0` that
          # has since been fully unpublished from the npm registry (packument
          # 404s). A real `npm ci` merely warns and omits it, which is why the
          # repo's Dockerfile still works, but nixpkgs' fetchNpmDeps downloads
          # every lockfile entry and fails hard on the dead tarball.
          #
          # Rather than mutate the committed package-lock.json, drop the dead
          # optional dep from a *build-only* copy of the lockfile.
          sanitizeScript = pkgs.writeText "strip-dead-optional.mjs" ''
            import { readFileSync, writeFileSync } from "node:fs";
            const p = process.argv[2];
            const lock = JSON.parse(readFileSync(p, "utf8"));
            let changed = false;
            // leaf entry (packages."node_modules/pg-hubflare")
            if (lock.packages?.["node_modules/pg-hubflare"]) {
              delete lock.packages["node_modules/pg-hubflare"];
              changed = true;
            }
            // reference from pg's optionalDependencies
            const pg = lock.packages?.["node_modules/pg"];
            if (pg?.optionalDependencies?.["pg-hubflare"]) {
              delete pg.optionalDependencies["pg-hubflare"];
              changed = true;
            }
            if (!changed) throw new Error("pg-hubflare not found; re-check whether it can be removed");
            writeFileSync(p, JSON.stringify(lock, null, 2) + "\n");
          '';

          cleanSrc = pkgs.runCommand "paseo-hub-clean-src" {
            nativeBuildInputs = [ nodejs ];
          } ''
            cp -r --no-preserve=mode,ownership ${src} $out
            chmod -R u+w $out
            node ${sanitizeScript} $out/package-lock.json
          '';
        in
        rec {
          paseo-hub = pkgs.buildNpmPackage {
            pname = "paseo-hub";
            version = "0.9.0";

            inherit nodejs;
            src = cleanSrc;

            # Offline npm dependency store built from the sanitized lock. Compute
            # via `nix build .#paseo-hub`: it fails fast and prints
            # `got: sha256-...`; paste that value here.
            npmDeps = pkgs.fetchNpmDeps {
              src = cleanSrc;
              hash = "sha256-nxovNBTMSBSFD2wXSp/KrXTc6tkIoswyi5rCcJmnRbc=";
            };

            # Root npm "build" = tsgo (build:node -> dist/) then vite
            # (build:start -> .output/). Runs after `npm ci` from npmDeps.
            npmBuildScript = "build";

            nativeBuildInputs = [ pkgs.makeWrapper ];

            # Playwright browsers are only needed for e2e tests, never to build
            # or run the Hub; stop the package install from trying to fetch them.
            env.PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";

            # Assemble a runtime layout mirroring the published npm package
            # (<pkg>/bin, dist, .output, drizzle + node_modules) so that
            # `node dist/index.js` finds its bundled assets via runtimeFile().
            # Ship our own `paseo-hub` launcher instead of npm bin shims.
            installPhase = ''
              runHook preInstall

              pkgDir="$out/lib/node_modules/paseo-hub"
              mkdir -p "$pkgDir" "$out/bin"

              cp -r node_modules "$pkgDir/node_modules"
              cp -r dist .output drizzle "$pkgDir/"
              cp package.json "$pkgDir/package.json"

              # Run dist/index.js from the package root so runtimeFile() (cwd
              # fallback) resolves .output and drizzle next to the binary, matching
              # `npm start` in the Docker image. Thread the system CA bundle so
              # outbound HTTPS (GitHub/Slack/Discord/Stripe/Resend) works on NixOS.
              makeWrapper "${nodejs}/bin/node" "$out/bin/paseo-hub" \
                --chdir "$pkgDir" \
                --add-flags "dist/index.js" \
                --prefix PATH : "${nodejs}/bin" \
                --set-default SSL_CERT_FILE "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" \
                --set-default NODE_EXTRA_CA_CERTS "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"

              runHook postInstall
            '';

            meta = with pkgs.lib; {
              description = "Self-hosted automation layer for Paseo daemons";
              homepage = "https://paseo.sh/docs/hub";
              license = licenses.asl20;
              platforms = platforms.linux ++ platforms.darwin;
              mainProgram = "paseo-hub";
            };
          };

          default = paseo-hub;
        });
    };
}
