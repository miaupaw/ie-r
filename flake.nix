{
    description = "Instant Eyedropper Reborn - Universal Command Center...";

    inputs = {
        nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
        rust-overlay.url = "github:oxalica/rust-overlay";
    };

    outputs = { self, nixpkgs, rust-overlay, ... }:
    let
        system = "x86_64-linux";
        pkgs = import nixpkgs {
            inherit system;
            overlays = [ (import rust-overlay) ];
        };

        # ── Toolchain ────────────────────────────────────────────────────────
        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
            extensions = [ "rust-src" "rust-analyzer" ];
        };

        rustPlatform = pkgs.makeRustPlatform {
            cargo = rustToolchain;
            rustc = rustToolchain;
        };

        # ── Dependencies ─────────────────────────────────────────────────────
        nativeDeps = with pkgs; [ pkg-config llvmPackages.libclang patchelf ];

        runtimeLibs = with pkgs; [
            pipewire
            wayland
            libxkbcommon
            dbus
            fontconfig
            xorg.libX11
            xorg.libXcursor
            xorg.libXrandr
            xorg.libXi
        ];

        libclangPath = "${pkgs.llvmPackages.libclang.lib}/lib";

        # ── Portable Scripts ──────────────────────────────────────────────────
        # NOTE: Must use #!/bin/sh — these scripts run on non-Nix systems (Ubuntu etc.)
        # pkgs.writeShellScript would embed #!/nix/store/... which breaks portability.
        portableLauncher = pkgs.writeTextFile {
            name = "ie-r";
            executable = true;
            text = '' # bash
                #!/bin/sh
                HERE="$(dirname "$(readlink -f "$0")")"
                export XKB_CONFIG_ROOT="$HERE/../share/xkb"
                export XLOCALEDIR="$HERE/../share/X11/locale"
                export IE_R_ICON_THEME_PATH="$HERE/../share/icons"
                exec "$HERE/../lib/ld-linux-x86-64.so.2" --library-path "$HERE/../lib" "$HERE/.ie-r-raw" "$@"
            '';
        };

        postinstallScript = pkgs.writeTextFile {
            name = "postinstall";
            executable = true;
            text = '' # bash
                #!/bin/sh
                HERE="$(dirname "$(readlink -f "$0")")"
                DESKTOP_DIR="$HOME/.local/share/applications"
                AUTOSTART_DIR="$HOME/.config/autostart"
                ICON_DIR="$HOME/.local/share/icons/hicolor/scalable/apps"
                ICON_SYMBOLIC_DIR="$HOME/.local/share/icons/hicolor/symbolic/apps"
                mkdir -p "$DESKTOP_DIR" "$AUTOSTART_DIR" "$ICON_DIR" "$ICON_SYMBOLIC_DIR"

                printf '%s\n' \
                    '[Desktop Entry]' \
                    'Name=Instant Eyedropper Reborn' \
                    'Comment=Pixel-perfect color picker. Native Wayland/KWin implementation.' \
                    "Exec=$HERE/bin/ie-r" \
                    'Icon=ie-r' \
                    'Type=Application' \
                    'Categories=Utility;Graphics;Development;' \
                    'StartupNotify=false' \
                    'Terminal=false' \
                    'StartupWMClass=ie-r' \
                    'SkipTaskbar=true' \
                    'X-KDE-DBUS-Restricted-Interfaces=org.kde.KWin.ScreenShot2' \
                    > "$DESKTOP_DIR/ie-r.desktop"

                chmod +x "$DESKTOP_DIR/ie-r.desktop"

                cp "$HERE/share/icons/hicolor/scalable/apps/ie-r.svg" "$ICON_DIR/ie-r.svg"
                cp "$HERE/share/icons/hicolor/symbolic/apps/ie-r-symbolic.svg" "$ICON_SYMBOLIC_DIR/ie-r-symbolic.svg"

                update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
                gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

                echo "✅ Desktop integration complete! IE-R is now in your application menu."

                printf "❓ Add IE-R to Autostart? (y/N): "
                read -r choice
                if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
                    cp "$DESKTOP_DIR/ie-r.desktop" "$AUTOSTART_DIR/"
                    echo "🚀 Added to autostart!"
                fi

                echo "--------------------------------------------------"
                echo "💡 WAYLAND HOTKEYS TIP:"
                echo "Global hotkeys can be tricky on Wayland (GNOME/KDE)."
                echo "For perfect reliability, set a 'Custom Shortcut' in your OS settings:"
                echo "   Command: /usr/bin/pkill -SIGUSR1 -f ie-r"
                echo "--------------------------------------------------"
                echo "🔗 Points to: $HERE/bin/ie-r"
            '';
        };

    in {
        # ── Dev Environment ──────────────────────────────────────────────────
        devShells.${system}.default = pkgs.mkShell {
            buildInputs = [ rustToolchain ] ++ nativeDeps ++ runtimeLibs;
            LIBCLANG_PATH = libclangPath;
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath runtimeLibs;

            shellHook = '' # bash
                echo -e "\033[1;32mIE-R\033[0m Command Center Active"
                echo -e "\033[0;90mRust: $(rustc --version)\033[0m"
            '';
        };

        # ── Commands & Apps ──────────────────────────────────────────────────
        apps.${system} = {
            default  = { type = "app"; program = "${self.packages.${system}.default}/bin/ie-r"; };
            appimage = { type = "app"; program = "${self.packages.${system}.appimage}"; };

            # The "Divine Distributor" - Builds, Extracts, Fixes Permissions, Zips
            bundle = {
                type = "app";
                program = let
                    script = pkgs.writeShellScriptBin "bundle-ie-r" '' # bash
                        echo -e "\033[1;32m🚀 Starting Divine Distribution...\033[0m"

                        BUNDLE_PATH=$(nix build .#portable --no-link --print-out-paths)
                        if [ -z "$BUNDLE_PATH" ]; then
                            echo -e "\033[1;31m❌ Build failed\033[0m"
                            exit 1
                        fi

                        VERSION="v0.1.0"
                        STAGE_DIR="tmp/staging"
                        FINAL_DIR="ie-r"
                        ZIP_NAME="ie-r-$VERSION.zip"

                        echo "📦 Extracting and cleaning structure..."
                        rm -rf "$STAGE_DIR" "$ZIP_NAME"
                        mkdir -p "$STAGE_DIR/$FINAL_DIR"

                        cp -rL "$BUNDLE_PATH"/* "$STAGE_DIR/$FINAL_DIR/"

                        echo "🔧 Leveling permissions (755)..."
                        chmod -R 755 "$STAGE_DIR/$FINAL_DIR"

                        echo "⚡ Archiving to $ZIP_NAME..."
                        cd "$STAGE_DIR"
                        ${pkgs.zip}/bin/zip -rq "../../$ZIP_NAME" "$FINAL_DIR"
                        cd - > /dev/null

                        echo -e "\033[1;32m✅ Done! Archive ready: ./$ZIP_NAME\033[0m"
                        echo "📂 Internal structure: $FINAL_DIR/{bin,lib,share}"
                    '';
                in "${script}/bin/bundle-ie-r";
            };
        };

        # ── Packages ─────────────────────────────────────────────────────────
        packages.${system} = rec {

            # 1. Native Nix Package
            default = rustPlatform.buildRustPackage {
                pname = "ie-r"; version = "0.1.0"; src = ./.;
                cargoLock.lockFile = ./Cargo.lock;
                doCheck = false; # ← skip cargo test in Nix sandbox
                nativeBuildInputs = nativeDeps;
                buildInputs = runtimeLibs;
                LIBCLANG_PATH = libclangPath;

                postInstall = '' # bash
                    install -Dm644 assets/ie-r.desktop -t $out/share/applications/
                    install -Dm644 assets/ie-r.svg -t $out/share/icons/hicolor/scalable/apps/
                    install -Dm644 assets/ie-r-symbolic.svg -t $out/share/icons/hicolor/symbolic/apps/
                    install -Dm644 LICENSE -t $out/share/licenses/ie-r/
                    substituteInPlace $out/share/applications/ie-r.desktop --replace-fail "Exec=ie-r" "Exec=$out/bin/ie-r"
                '';

                postFixup = '' # bash
                    patchelf --set-rpath "${pkgs.lib.makeLibraryPath runtimeLibs}" $out/bin/ie-r
                '';
            };

            # 2. Relocatable Bundle (The core logic for distribution)
            portable = pkgs.stdenv.mkDerivation {
                name = "ie-r-portable";
                nativeBuildInputs = [ pkgs.patchelf ];
                phases = [ "installPhase" ];

                installPhase = '' # bash
                    mkdir -p $out/{bin,lib,share/X11/locale}

                    # 1. Binary & Library Gathering (Surgical approach)
                    cp -v ${default}/bin/ie-r $out/bin/.ie-r-raw
                    chmod +w $out/bin/.ie-r-raw

                    echo "🔍 Harvesting REQUIRED runtime libraries..."
                    # 1a. Gather direct dependencies of the binary
                    ldd $out/bin/.ie-r-raw | awk '{print $3}' | grep "^/nix/store" > libs_list

                    # 1b. Force-include X11/Wayland/Pipewire entry points for dlopen()
                    echo "🔦 Locating dlopen entry points (X11 + Wayland + Pipewire)..."
                    for lib in \
                        ${pkgs.wayland}/lib/libwayland-client.so.0 \
                        ${pkgs.xorg.libX11}/lib/libX11.so.6 \
                        ${pkgs.xorg.libX11}/lib/libX11-xcb.so.1 \
                        ${pkgs.xorg.libXcursor}/lib/libXcursor.so.1 \
                        ${pkgs.xorg.libXrandr}/lib/libXrandr.so.2 \
                        ${pkgs.xorg.libXi}/lib/libXi.so.6 \
                        ${pkgs.xorg.libXrender}/lib/libXrender.so.1 \
                        ${pkgs.libxkbcommon}/lib/libxkbcommon-x11.so.0 \
                        ${pkgs.pipewire}/lib/libpipewire-0.3.so.0; \
                    do
                        echo "$lib" >> libs_list
                    done

                    # 1c. First pass copy (following symlinks to be standalone)
                    sort -u libs_list | xargs -I{} cp -nL {} $out/lib/ 2>/dev/null || true

                    # 1d. Recursive pass: trace dependencies of everything gathered so far
                    # This pulls in libxcb, libXau, libXdmcp, etc.
                    ldd $out/lib/*.so* 2>/dev/null | awk '{print $3}' | grep "^/nix/store" | sort -u | xargs -I{} cp -nL {} $out/lib/ 2>/dev/null || true

                    # 2. Assets, Loader & Permissions
                    chmod +w $out/lib/* $out/bin/.ie-r-raw
                    cp -vL "${pkgs.glibc.out}/lib/ld-linux-x86-64.so.2" $out/lib/

                    echo "✂️  Trimming XKB and Locale fat..."
                    mkdir -p $out/share/xkb/{rules,keycodes,symbols,types,compat}
                    cp -R ${pkgs.xkeyboard_config}/share/X11/xkb/rules/evdev*         $out/share/xkb/rules/
                    cp -R ${pkgs.xkeyboard_config}/share/X11/xkb/keycodes/evdev       $out/share/xkb/keycodes/
                    cp -R ${pkgs.xkeyboard_config}/share/X11/xkb/keycodes/aliases     $out/share/xkb/keycodes/
                    cp -R ${pkgs.xkeyboard_config}/share/X11/xkb/symbols/{pc,us,inet,srvr_ctrl,group,keypad} $out/share/xkb/symbols/
                    cp -R ${pkgs.xkeyboard_config}/share/X11/xkb/types/*              $out/share/xkb/types/
                    cp -R ${pkgs.xkeyboard_config}/share/X11/xkb/compat/*             $out/share/xkb/compat/

                    mkdir -p $out/share/X11/locale
                    cp -R ${pkgs.xorg.libX11}/share/X11/locale/en_US.UTF-8 $out/share/X11/locale/
                    cp -R ${pkgs.xorg.libX11}/share/X11/locale/compose.dir $out/share/X11/locale/
                    cp -R ${pkgs.xorg.libX11}/share/X11/locale/locale.alias $out/share/X11/locale/
                    cp -R ${pkgs.xorg.libX11}/share/X11/locale/locale.dir   $out/share/X11/locale/

                    mkdir -p $out/share/icons/hicolor/scalable/apps
                    mkdir -p $out/share/icons/hicolor/symbolic/apps
                    cp ${default}/share/icons/hicolor/scalable/apps/ie-r.svg $out/share/icons/hicolor/scalable/apps/
                    cp ${default}/share/icons/hicolor/symbolic/apps/ie-r-symbolic.svg $out/share/icons/hicolor/symbolic/apps/
                    printf '%s\n' \
                        '[Icon Theme]'              \
                        'Name=hicolor'              \
                        'Comment=Hicolor theme'     \
                        'Directories=scalable/apps symbolic/apps' \
                        '[scalable/apps]'           \
                        'Size=48'                   \
                        'MinSize=1'                 \
                        'MaxSize=512'               \
                        'Type=Scalable'             \
                        '[symbolic/apps]'           \
                        'Size=16'                   \
                        'MinSize=16'                \
                        'MaxSize=512'               \
                        'Type=Scalable'             \
                        > $out/share/icons/hicolor/index.theme
                    cp ${default}/share/applications/ie-r.desktop $out/share/
                    cp ${default}/share/licenses/ie-r/LICENSE $out/

                    patchelf --set-rpath '$ORIGIN/../lib' $out/bin/.ie-r-raw

                    # 3. Scripts
                    cp ${postinstallScript} $out/postinstall.sh
                    chmod +x $out/postinstall.sh

                    cp ${portableLauncher} $out/bin/ie-r
                    chmod +x $out/bin/ie-r
                '';
            };

            # 3. AppImage
            appimage = pkgs.stdenv.mkDerivation {
                pname = "ie-r-appimage"; version = "0.1.0"; src = ./.;
                nativeBuildInputs = [ pkgs.appimagekit ];
                buildCommand = '' # bash
                    mkdir -p AppDir/usr
                    cp -rL ${portable}/* AppDir/usr/

                    # AppImage specific adjustments
                    mv AppDir/usr/share/ie-r.desktop AppDir/
                    cp AppDir/usr/share/icons/hicolor/scalable/apps/ie-r.svg AppDir/
                    ln -s ie-r.svg AppDir/.DirIcon
                    ln -s bin/ie-r AppDir/AppRun

                    export ARCH=x86_64 && appimagetool AppDir $out
                '';
            };
        };
    };
}
