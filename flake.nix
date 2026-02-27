{
  description = "ESP-IDF (worktrees) + Matter build deps (NixOS-friendly)";
  inputs.nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.2511";
  outputs =
    {
      nixpkgs,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      lib = pkgs.lib;

      # turns "v5.5.1" -> "idf_v5_5_1"
      tagToShellName = tag: "idf_" + builtins.replaceStrings [ "." ] [ "_" ] tag;

      # Keep LD_LIBRARY_PATH *minimal* to avoid glibc skew issues with /bin/sh.
      # This is only for Python ctypes (e.g. pgi) runtime loading.
      pythonRuntimeLibs = with pkgs; [
        glib
        gobject-introspection
        libffi
      ];

      # Build-time packages for ESP-IDF + Matter host builds.
      buildPkgs = (
        with pkgs;
        [
          git
          gcc
          cmake
          pkg-config
          gn
          ninja
          curl
          unzip

          python311
          python311Packages.pip
          python311Packages.virtualenv

          # Matter docs prerequisites (headers)
          openssl.dev
          dbus.dev
          glib.dev
          avahi.dev
          gobject-introspection.dev
          cairo.dev
          readline.dev
          libevent.dev

          # Runtime libs also often needed at build/link time
          openssl
          dbus
          glib
          avahi
          gobject-introspection
          cairo
          readline
          libevent

          # JRE (Matter docs list default-jre)
          temurin-jre-bin

          # optional helpers
          ccache
        ]
      );

      mkIdfShell =
        tag:
        let
          idfEnsure = pkgs.writeShellScriptBin "idf-ensure" ''
            set -euo pipefail

            REPO_DIR="$1"
            TAG="$2"
            WT_DIR="$3"
            URL="https://github.com/espressif/esp-idf.git"

            # allow opting out (useful when offline)
            : "''${IDF_AUTO_FETCH:=1}"

            # shallow fetch only the requested tag (default on)
            : "''${IDF_SHALLOW:=1}"

            # shallow init/update submodules (default on)
            : "''${IDF_SUBMODULE_SHALLOW:=1}"

            if [ ! -d "$REPO_DIR/.git" ]; then
              mkdir -p "$(dirname "$REPO_DIR")"
              git clone "$URL" "$REPO_DIR"
            fi

            if [ "$IDF_AUTO_FETCH" = "1" ]; then
              if [ "$IDF_SHALLOW" = "1" ]; then
                # Fetch only the requested tag, shallow
                git -C "$REPO_DIR" fetch --depth 1 origin "refs/tags/$TAG:refs/tags/$TAG"
              else
                # Original behavior
                git -C "$REPO_DIR" fetch --tags --prune
              fi
            fi

            # Clean stale worktree registrations (fixes "missing but already registered worktree")
            git -C "$REPO_DIR" worktree prune --verbose || true

            if [ ! -d "$WT_DIR" ]; then
              # If still registered somehow, try to unlock + prune again
              if git -C "$REPO_DIR" worktree list --porcelain | grep -Fx "worktree $WT_DIR" >/dev/null; then
                git -C "$REPO_DIR" worktree unlock "$WT_DIR" 2>/dev/null || true
                git -C "$REPO_DIR" worktree prune --verbose || true
              fi

              git -C "$REPO_DIR" worktree add "$WT_DIR" "$TAG"
            else
              # WT_DIR exists: ensure it's actually a worktree of REPO_DIR
              if ! git -C "$REPO_DIR" worktree list --porcelain | grep -Fx "worktree $WT_DIR" >/dev/null; then
                echo "ERROR: $WT_DIR exists but is not a worktree of $REPO_DIR" >&2
                exit 1
              fi

              # refuse to clobber local changes
              if ! git -C "$WT_DIR" diff --quiet || ! git -C "$WT_DIR" diff --cached --quiet; then
                echo "ERROR: $WT_DIR has local changes; refusing to switch to $TAG" >&2
                exit 1
              fi

              git -C "$WT_DIR" checkout -f "$TAG"
            fi

            # Always ensure submodules match the checked-out tag
            git -C "$WT_DIR" submodule sync --recursive
            if [ "$IDF_SUBMODULE_SHALLOW" = "1" ]; then
              git -C "$WT_DIR" submodule update --init --recursive --depth 1
            else
              git -C "$WT_DIR" submodule update --init --recursive
            fi
          '';

          # Runs install.sh once per tag (marker file in IDF_TOOLS_PATH)
          idfAutoInstall = pkgs.writeShellScriptBin "idf-auto-install" ''
            set -euo pipefail

            TAG="$1"
            IDF_PATH="$2"

            : "''${IDF_AUTO_INSTALL:=1}"     # set 0 to disable
            : "''${IDF_TOOLS_PATH:?IDF_TOOLS_PATH not set}"

            if [ "$IDF_AUTO_INSTALL" != "1" ]; then
              exit 0
            fi

            mkdir -p "$IDF_TOOLS_PATH"

            safe_tag="$(echo "$TAG" | tr -c 'A-Za-z0-9._-' '_')"
            marker="$IDF_TOOLS_PATH/.esp-idf-installed-$safe_tag"
            lockdir="$IDF_TOOLS_PATH/.esp-idf-install-lock-$safe_tag"

            if [ -f "$marker" ]; then
              exit 0
            fi

            # lock to prevent concurrent installs
            if mkdir "$lockdir" 2>/dev/null; then
              cleanup() { rmdir "$lockdir" 2>/dev/null || true; }
              trap cleanup EXIT

              # re-check after acquiring lock
              if [ ! -f "$marker" ]; then
                echo "ESP-IDF tools not found for $TAG; running install.sh..."
                "$IDF_PATH/install.sh" --enable-pytest --enable-test-specific
                # optional extra
                python3 "$IDF_PATH/tools/idf_tools.py" install esp-clang

                date -Is > "$marker"
                echo "ESP-IDF install finished for $TAG."
              fi
            else
              echo "Another shell is installing ESP-IDF tools for $TAG; waiting..."
              while [ ! -f "$marker" ]; do sleep 2; done
            fi
          '';

          idfInstall = pkgs.writeShellScriptBin "idf-install" ''
            set -euo pipefail
            : "''${IDF_PATH:?IDF_PATH not set; did export.sh run?}"

            echo "Installing ESP-IDF tools for $IDF_PATH"
            "$IDF_PATH/install.sh" --enable-pytest --enable-test-specific
            python3 "$IDF_PATH/tools/idf_tools.py" install esp-clang
            echo "ESP-IDF installation finished."
          '';
        in
        pkgs.mkShellNoCC {
          name = "idf-${tag}";

          packages = buildPkgs ++ [
            idfEnsure
            idfAutoInstall
            idfInstall
          ];

          shellHook = ''
            export IDF_CCACHE_ENABLE=1
            export CCACHE_NOHASHDIR=1
            export CCACHE_SLOPPINESS="locale,time_macros,random_seed"

            export IDF_REPO_DIR="$HOME/.local/share/esp-idf-repo"
            export IDF_WORKTREE_DIR="$HOME/.local/share/esp-idf-${tag}"

            # shared tool install location across versions:
            export IDF_TOOLS_PATH="$HOME/.local/share/esp-idf-tools"

            ${idfEnsure}/bin/idf-ensure "$IDF_REPO_DIR" "${tag}" "$IDF_WORKTREE_DIR"

            # Ensure tools are installed BEFORE sourcing export.sh
            export IDF_PATH="$IDF_WORKTREE_DIR"
            ${idfAutoInstall}/bin/idf-auto-install "${tag}" "$IDF_PATH"

            # Now activation should succeed
            . "$IDF_PATH/export.sh"

            # Minimal LD_LIBRARY_PATH for Python ctypes (e.g. pgi needing libglib-2.0.so.0).
            export LD_LIBRARY_PATH="${lib.makeLibraryPath pythonRuntimeLibs}:''${LD_LIBRARY_PATH-}"

            # Optional: helps GI find typelibs
            export GI_TYPELIB_PATH="${
              lib.makeSearchPath "lib/girepository-1.0" [
                pkgs.glib
                pkgs.gobject-introspection
              ]
            }:''${GI_TYPELIB_PATH-}"
          '';
        };

      tags = [
        "v5.5.2"
        "v5.5.3"
        "v5.4.1"
        "v5.4.2"
        "v5.4.3"
      ];

      shellsFromTags = builtins.listToAttrs (
        map (tag: {
          name = tagToShellName tag;
          value = mkIdfShell tag;
        }) tags
      );

    in
    {
      devShells.${system} = shellsFromTags // {
        default = mkIdfShell "v5.5.3";
      };
    };
}
