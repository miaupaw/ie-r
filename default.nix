{ pkgs ? import <nixpkgs> {} }:

let
  runtimeLibs = with pkgs; [
    pipewire wayland libxkbcommon dbus fontconfig
    xorg.libX11 xorg.libXcursor xorg.libXrandr xorg.libXi
  ];
in

pkgs.rustPlatform.buildRustPackage {
  pname = "ie-r";
  version = "0.1.0";

  src = pkgs.fetchFromGitHub {
    owner = "miaupaw";
    repo  = "ie-r";
    rev   = "v0.1.0";
    hash  = "sha256-bfhOrwcJn4B8UpkAA59YVa9HH29fDcTcMBA7Ot4mwOw=";
  };

  cargoLock.lockFile = ./Cargo.lock;

  doCheck = false;
  nativeBuildInputs = with pkgs; [ pkg-config llvmPackages.libclang patchelf ];
  buildInputs = runtimeLibs;
  LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";

  postInstall = ''
    install -Dm644 assets/ie-r.desktop -t $out/share/applications/
    install -Dm644 assets/ie-r.svg -t $out/share/icons/hicolor/scalable/apps/
    install -Dm644 LICENSE -t $out/share/licenses/ie-r/
    substituteInPlace $out/share/applications/ie-r.desktop \
      --replace-fail "Exec=ie-r" "Exec=$out/bin/ie-r"
  '';
}
