{
  description = "ESP-IDF (worktrees) + Matter build deps (NixOS-friendly)";
  inputs.nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.2511";
  outputs =
    {
      nixpkgs,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # turns "v5.5.1" -> "idf_v5_5_1"
      tagToShellName = tag: "idf_" + builtins.replaceStrings [ "." ] [ "_" ] tag;

      tags = [
        "v5.4.1"
        "v5.4.2"
        "v5.5.1"
      ];
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          lib = pkgs.lib;

          mkIdfShell =
            tag:
            let
              idfSync = pkgs.writeShellScriptBin "idf-sync" ''
                set -euo pipefail

                TAG="${tag}"
                URL="https://github.com/espressif/esp-idf.git"

                : "''${IDF_REPO_DIR:=$HOME/.local/share/esp-idf-repo}"
                : "''${IDF_WORKTREE_DIR:=$HOME/.local/share/esp-idf-$TAG}"
                : "''${IDF_TOOLS_PATH:=$HOME/.local/share/esp-idf-tools}"
                : "''${IDF_PATH:=$IDF_WORKTREE_DIR}"

                REPO_DIR="$IDF_REPO_DIR"
                WT_DIR="$IDF_WORKTREE_DIR"

                if [ "$IDF_PATH" != "$WT_DIR" ]; then
                  echo "ERROR: IDF_PATH ($IDF_PATH) must match IDF_WORKTREE_DIR ($WT_DIR) for idf-sync." >&2
                  echo "Set IDF_WORKTREE_DIR first, or unset IDF_PATH." >&2
                  exit 1
                fi

                if [ ! -d "$REPO_DIR/.git" ]; then
                  mkdir -p "$(dirname "$REPO_DIR")"
                  git clone "$URL" "$REPO_DIR"
                fi

                git -C "$REPO_DIR" fetch --tags --force --prune origin

                # Clean stale worktree registrations.
                git -C "$REPO_DIR" worktree prune --verbose || true

                if [ ! -d "$WT_DIR" ]; then
                  mkdir -p "$(dirname "$WT_DIR")"

                  # If still registered somehow, try to unlock + prune again.
                  if git -C "$REPO_DIR" worktree list --porcelain | grep -Fx "worktree $WT_DIR" >/dev/null; then
                    git -C "$REPO_DIR" worktree unlock "$WT_DIR" 2>/dev/null || true
                    git -C "$REPO_DIR" worktree prune --verbose || true
                  fi

                  git -C "$REPO_DIR" worktree add "$WT_DIR" "$TAG"
                else
                  # WT_DIR exists: ensure it's actually a worktree of REPO_DIR.
                  if ! git -C "$REPO_DIR" worktree list --porcelain | grep -Fx "worktree $WT_DIR" >/dev/null; then
                    echo "ERROR: $WT_DIR exists but is not a worktree of $REPO_DIR" >&2
                    exit 1
                  fi

                  # Refuse to clobber local changes.
                  if ! git -C "$WT_DIR" diff --quiet || ! git -C "$WT_DIR" diff --cached --quiet; then
                    echo "ERROR: $WT_DIR has local changes; refusing to update to $TAG" >&2
                    exit 1
                  fi

                  git -C "$WT_DIR" checkout -f "$TAG"
                fi

                git -C "$WT_DIR" reset --hard "$TAG"

                # Ensure submodules match the checked-out tag.
                git -C "$WT_DIR" submodule sync --recursive
                git -C "$WT_DIR" submodule update --init --recursive --depth 1

                mkdir -p "$IDF_TOOLS_PATH"
                export IDF_PATH="$WT_DIR"
                export IDF_TOOLS_PATH

                echo "Installing ESP-IDF tools for $IDF_PATH"
                "$IDF_PATH/install.sh" --enable-pytest --enable-test-specific
                python3 "$IDF_PATH/tools/idf_tools.py" install esp-clang
                echo "ESP-IDF sync and install finished for $TAG."
              '';
            in
            pkgs.mkShellNoCC (
              {
                name = "idf-${tag}";

                IDF_CCACHE_ENABLE = "1";
                CCACHE_NOHASHDIR = "1";
                CCACHE_SLOPPINESS = "locale,time_macros,random_seed";

                packages =
                  (
                    # Build-time packages for ESP-IDF + Matter host builds.
                    with pkgs; [
                      git
                      gcc
                      cmake
                      pkg-config
                      ninja
                      curl
                      unzip
                      zip
                      gperf

                      python311
                      python311Packages.pip
                      python311Packages.setuptools
                      python311Packages.wheel
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
                    ])
                  ++ [
                    idfSync
                  ];

                shellHook = ''
                  export IDF_REPO_DIR="''${IDF_REPO_DIR:-$HOME/.local/share/esp-idf-repo}"
                  export IDF_WORKTREE_DIR="''${IDF_WORKTREE_DIR:-$HOME/.local/share/esp-idf-${tag}}"
                  export IDF_TOOLS_PATH="''${IDF_TOOLS_PATH:-$HOME/.local/share/esp-idf-tools}"
                  export IDF_PATH="''${IDF_PATH:-$IDF_WORKTREE_DIR}"

                  # Vacuum stale worktree registrations when users delete worktree dirs directly.
                  if [ -d "$IDF_REPO_DIR/.git" ]; then
                    git -C "$IDF_REPO_DIR" worktree prune >/dev/null 2>&1 || true
                  fi

                  # Warn when the host ELF interpreter shim is missing or still points to stub-ld.
                  host_interp=""
                  case "$(uname -m)" in
                    x86_64) host_interp="/lib64/ld-linux-x86-64.so.2" ;;
                    aarch64) host_interp="/lib/ld-linux-aarch64.so.1" ;;
                  esac

                  if [ -n "$host_interp" ]; then
                    resolved_interp="$(readlink -f "$host_interp" 2>/dev/null || true)"
                    needs_nix_ld_warn=0

                    if [ ! -e "$host_interp" ]; then
                      needs_nix_ld_warn=1
                    elif [ -n "$resolved_interp" ] && printf '%s' "$resolved_interp" | grep -q 'stub-ld'; then
                      needs_nix_ld_warn=1
                    fi

                    if [ "$needs_nix_ld_warn" -eq 1 ]; then
                      if [ -t 1 ]; then
                        yellow='\033[33m'
                        reset='\033[0m'
                        printf '%b\n' "''${yellow}nix-ld interpreter shim is not active (missing or points to stub-ld).''${reset}"
                        printf '%b\n' "''${yellow}Enable nix-ld in your NixOS config (e.g. programs.nix-ld.enable = true;).''${reset}"
                      else
                        echo "nix-ld interpreter shim is not active (missing or points to stub-ld)."
                        echo "Enable nix-ld in your NixOS config (e.g. programs.nix-ld.enable = true;)."
                      fi
                    fi
                  fi

                  if [ -f "$IDF_PATH/export.sh" ]; then
                    . "$IDF_PATH/export.sh"
                  else
                      if [ -t 1 ]; then
                        yellow='\033[33m'
                        reset='\033[0m'
                        printf '%b\n' "''${yellow}ESP-IDF not initialized for ${tag} at $IDF_PATH''${reset}"
                        printf '%b\n' "''${yellow}Run 'idf-sync', then source \"$IDF_PATH/export.sh\" or re-enter this shell.''${reset}"
                      else
                        echo "ESP-IDF not initialized for ${tag} at $IDF_PATH"
                        echo "Run 'idf-sync', then source \"$IDF_PATH/export.sh\" or re-enter this shell."
                      fi
                    fi
                '';
              }
              // lib.optionalAttrs pkgs.stdenv.isLinux {
                NIX_LD = lib.fileContents "${pkgs.stdenv.cc}/nix-support/dynamic-linker";
                NIX_LD_LIBRARY_PATH = lib.makeLibraryPath (
                  with pkgs;
                  [
                    glibc
                    pkgsi686Linux.glibc
                    stdenv.cc.cc
                    zlib
                    openssl
                    libffi
                    glib
                    gobject-introspection
                    dbus
                    dbus-glib
                    avahi
                    libevent
                    cairo
                    readline
                    util-linux
                    systemd
                    libusb1
                    ncurses5
                    ncurses
                  ]
                );
              }
            );

          shellsFromTags = builtins.listToAttrs (
            map (tag: {
              name = tagToShellName tag;
              value = mkIdfShell tag;
            }) tags
          );
        in
        shellsFromTags
        // {
          default = mkIdfShell "v5.4.1";
        }
      );
    };
}
