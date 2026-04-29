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
            targets = [ "x86_64-pc-windows-gnu" ];
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
            libx11
            libxcursor
            libxrandr
            libxi
        ];

        libclangPath = "${pkgs.llvmPackages.libclang.lib}/lib";

        # ── Cross-compilation toolchain (Windows) ──────────────────────────
        mingwCC = pkgs.pkgsCross.mingwW64.stdenv.cc;
        mingwPthreads = pkgs.pkgsCross.mingwW64.windows.pthreads;

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
                export IE_R_FONT_DIR="$HERE/../fonts"
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
            buildInputs = [ rustToolchain mingwCC mingwPthreads ] ++ nativeDeps ++ runtimeLibs;
            LIBCLANG_PATH = libclangPath;
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath runtimeLibs;
            CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = "${mingwCC}/bin/x86_64-w64-mingw32-gcc";
            CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS = "-L ${mingwPthreads}/lib";

            shellHook = '' # bash
                echo -e "\033[1;32mIE-R\033[0m Command Center Active"
                echo -e "\033[0;90mRust: $(rustc --version)\033[0m"
            '';
        };

        # ── Commands & Apps ──────────────────────────────────────────────────
        apps.${system} = {
            default  = { type = "app"; program = "${self.packages.${system}.default}/bin/ie-r"; };
            appimage = { type = "app"; program = "${self.packages.${system}.appimage}"; };

            # Windows installer — run with: nix run .#windows-installer
            # Self-contained: builds exe + assembles bundle + runs NSIS
            # Produces: ie-r-setup-vVERSION.exe
            windows-installer = {
                type = "app";
                program = let
                    script = pkgs.writeShellScriptBin "windows-installer-ie-r" '' # bash
                        echo -e "\033[1;32m📦 Building IE-R Windows Installer...\033[0m"

                        # Generate native Windows .ico from SVG.
                        # --raw=FILE: embeds 256px PNG as-is inside ICO (Vista format, ~14KB).
                        # Smaller frames converted to BMP — windres handles these correctly.
                        # Plain ImageMagick generates BMP for 256px which windres embeds incorrectly.
                        echo "🎨 Generating native icons..."
                        _ICO_TMP=$(mktemp -d)
                        _TRAY_OBJ=$(mktemp --suffix=.o)
                        _TRAY_EXE=$(mktemp --suffix=.exe)
                        trap "rm -rf $_ICO_TMP $_TRAY_OBJ $_TRAY_EXE" EXIT
                        for SZ in 256 64 48 32 16; do
                            ${pkgs.imagemagick}/bin/magick -background none assets/ie-r.svg \
                                -resize ''${SZ}x''${SZ} PNG32:$_ICO_TMP/''${SZ}.png
                        done
                        ${pkgs.icoutils}/bin/icotool -c \
                            --raw=$_ICO_TMP/256.png \
                            -o assets/ie-r.ico \
                            $_ICO_TMP/64.png $_ICO_TMP/48.png \
                            $_ICO_TMP/32.png $_ICO_TMP/16.png

                        echo "🔧 Compiling C tray launcher..."
                        ${mingwCC}/bin/x86_64-w64-mingw32-windres launcher/ie-r-tray.rc --codepage 65001 -O coff -o "$_TRAY_OBJ"
                        ${mingwCC}/bin/x86_64-w64-mingw32-gcc -mwindows -O2 -s launcher/ie-r-tray.c "$_TRAY_OBJ" -o "$_TRAY_EXE"

                        export PATH="${rustToolchain}/bin:${mingwCC}/bin:$PATH"
                        export LIBCLANG_PATH="${libclangPath}"
                        export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER="${mingwCC}/bin/x86_64-w64-mingw32-gcc"
                        export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS="-L ${mingwPthreads}/lib"

                        cargo build --release --target x86_64-pc-windows-gnu --bin ie-r || exit 1

                        BUNDLE="$PWD/tmp/installer-bundle"
                        rm -rf "$BUNDLE"
                        mkdir -p "$BUNDLE/fonts"
                        cp target/x86_64-pc-windows-gnu/release/ie-r.exe "$BUNDLE/ie-r.exe"
                        cp "$_TRAY_EXE"                                   "$BUNDLE/ie-r-tray.exe"
                        cp ${pkgs.jetbrains-mono}/share/fonts/truetype/JetBrainsMono-Regular.ttf "$BUNDLE/fonts/JetBrainsMono-Regular.ttf"
                        cp ${./assets/fonts/OFL.txt}       "$BUNDLE/fonts/OFL.txt"
                        cp ${./LICENSE}                    "$BUNDLE/LICENSE"
                        cp ${./README.portable.windows.md} "$BUNDLE/README.md"
                        cp ${./PRIVACY.md}                 "$BUNDLE/PRIVACY.md"
                        cp ${./SECURITY.md}                "$BUNDLE/SECURITY.md"

                        ${pkgs.nsis}/bin/makensis \
                            -DBUNDLE="$BUNDLE" \
                            -DOUTDIR="$PWD" \
                            ${./assets/installer.nsi}

                        rm -rf "$BUNDLE"
                        echo -e "\033[1;32m✅ Done! ie-r-setup-v0.1.1.exe ready.\033[0m"
                    '';
                in "${script}/bin/windows-installer-ie-r";
            };

            # Windows portable bundle — run with: nix run .#windows-bundle
            # Produces: ie-r-portable-vVERSION.zip → {ie-r.exe, fonts/, LICENSE, README.md, PRIVACY.md, SECURITY.md}
            windows-bundle = {
                type = "app";
                program = let
                    script = pkgs.writeShellScriptBin "windows-bundle-ie-r" '' # bash
                        echo -e "\033[1;32m🪟 Building IE-R Windows Portable...\033[0m"

                        # Generate native Windows .ico from SVG.
                        # --raw=FILE: embeds 256px PNG as-is inside ICO (Vista format, ~14KB).
                        # Smaller frames converted to BMP — windres handles these correctly.
                        # Plain ImageMagick generates BMP for 256px which windres embeds incorrectly.
                        echo "🎨 Generating native icons..."
                        _ICO_TMP=$(mktemp -d)
                        _TRAY_OBJ=$(mktemp --suffix=.o)
                        _TRAY_EXE=$(mktemp --suffix=.exe)
                        trap "rm -rf $_ICO_TMP $_TRAY_OBJ $_TRAY_EXE" EXIT
                        for SZ in 256 64 48 32 16; do
                            ${pkgs.imagemagick}/bin/magick -background none assets/ie-r.svg \
                                -resize ''${SZ}x''${SZ} PNG32:$_ICO_TMP/''${SZ}.png
                        done
                        ${pkgs.icoutils}/bin/icotool -c \
                            --raw=$_ICO_TMP/256.png \
                            -o assets/ie-r.ico \
                            $_ICO_TMP/64.png $_ICO_TMP/48.png \
                            $_ICO_TMP/32.png $_ICO_TMP/16.png

                        echo "🔧 Compiling C tray launcher..."
                        ${mingwCC}/bin/x86_64-w64-mingw32-windres launcher/ie-r-tray.rc --codepage 65001 -O coff -o "$_TRAY_OBJ"
                        ${mingwCC}/bin/x86_64-w64-mingw32-gcc -mwindows -O2 -s launcher/ie-r-tray.c "$_TRAY_OBJ" -o "$_TRAY_EXE"

                        export PATH="${rustToolchain}/bin:${mingwCC}/bin:$PATH"
                        export LIBCLANG_PATH="${libclangPath}"
                        export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER="${mingwCC}/bin/x86_64-w64-mingw32-gcc"
                        export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS="-L ${mingwPthreads}/lib"

                        cargo build --release --target x86_64-pc-windows-gnu --bin ie-r || exit 1

                        VERSION="v0.1.1"
                        STAGE_DIR="tmp/staging-windows"
                        FINAL_DIR="ie-r"
                        ZIP_NAME="ie-r-portable-$VERSION.zip"

                        echo "📦 Assembling bundle..."
                        rm -rf "$STAGE_DIR" "$ZIP_NAME"
                        mkdir -p "$STAGE_DIR/$FINAL_DIR/fonts"

                        cp target/x86_64-pc-windows-gnu/release/ie-r.exe "$STAGE_DIR/$FINAL_DIR/"
                        cp "$_TRAY_EXE" "$STAGE_DIR/$FINAL_DIR/ie-r-tray.exe"
                        cp ${pkgs.jetbrains-mono}/share/fonts/truetype/JetBrainsMono-Regular.ttf "$STAGE_DIR/$FINAL_DIR/fonts/JetBrainsMono-Regular.ttf"
                        cp ${./assets/fonts/OFL.txt}       "$STAGE_DIR/$FINAL_DIR/fonts/OFL.txt"
                        cp ${./LICENSE}                    "$STAGE_DIR/$FINAL_DIR/LICENSE"
                        cp ${./README.portable.windows.md} "$STAGE_DIR/$FINAL_DIR/README.md"
                        cp ${./PRIVACY.md}                 "$STAGE_DIR/$FINAL_DIR/PRIVACY.md"
                        cp ${./SECURITY.md}                "$STAGE_DIR/$FINAL_DIR/SECURITY.md"

                        echo "⚡ Archiving to $ZIP_NAME..."
                        cd "$STAGE_DIR"
                        ${pkgs.zip}/bin/zip -rq "../../$ZIP_NAME" "$FINAL_DIR"
                        cd - > /dev/null

                        echo -e "\033[1;32m✅ Done! Archive ready: ./$ZIP_NAME\033[0m"
                        echo "📂 ie-r/{ie-r.exe, fonts/, LICENSE, README.md, PRIVACY.md, SECURITY.md}"
                    '';
                in "${script}/bin/windows-bundle-ie-r";
            };

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

                        VERSION="v0.1.1"
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
                pname = "ie-r"; version = "0.1.1"; src = ./.;
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
                    install -Dm644 ${pkgs.jetbrains-mono}/share/fonts/truetype/JetBrainsMono-Regular.ttf \
                        -t $out/share/ie-r/fonts/
                    install -Dm644 assets/fonts/OFL.txt -t $out/share/ie-r/fonts/
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
                        ${pkgs.libx11}/lib/libX11.so.6 \
                        ${pkgs.libx11}/lib/libX11-xcb.so.1 \
                        ${pkgs.libxcursor}/lib/libXcursor.so.1 \
                        ${pkgs.libxrandr}/lib/libXrandr.so.2 \
                        ${pkgs.libxi}/lib/libXi.so.6 \
                        ${pkgs.libxrender}/lib/libXrender.so.1 \
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
                    cp -R ${pkgs.libx11}/share/X11/locale/en_US.UTF-8 $out/share/X11/locale/
                    cp -R ${pkgs.libx11}/share/X11/locale/compose.dir $out/share/X11/locale/
                    cp -R ${pkgs.libx11}/share/X11/locale/locale.alias $out/share/X11/locale/
                    cp -R ${pkgs.libx11}/share/X11/locale/locale.dir   $out/share/X11/locale/

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

                    mkdir -p $out/fonts
                    cp ${pkgs.jetbrains-mono}/share/fonts/truetype/JetBrainsMono-Regular.ttf $out/fonts/
                    cp ${./assets/fonts/OFL.txt} $out/fonts/
                    cp ${./README.portable.md} $out/README.md
                    cp ${./PRIVACY.md} $out/PRIVACY.md
                    cp ${./SECURITY.md} $out/SECURITY.md

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
                pname = "ie-r-appimage"; version = "0.1.1"; src = ./.;
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
