#!/usr/bin/env bash
#
# Baut OpenSSL + libssh2 statisch für Apple-Plattformen und bündelt sie als
# zwei .xcframeworks unter Vendor/:
#
#   Vendor/openssl.xcframework   (libssl + libcrypto, zu libopenssl.a gemerged)
#   Vendor/libssh2.xcframework   (libssh2.a, gegen obiges OpenSSL gelinkt)
#
# Diese ersetzen die Homebrew-/systemLibrary-Abhängigkeit von Shout, damit der
# SSH-Stack auf macOS UND iOS (Device + Simulator) baut.
#
# Krypto-Backend bewusst OpenSSL: nur damit beherrscht libssh2 die von kiz0
# (OpenSSH 9.x) genutzten Verfahren — curve25519-sha256, aes-ctr/gcm,
# ssh-ed25519-Hostkeys und rsa-sha2-256/512-Pubkey-Auth.
#
# Default: nur arm64-Slices (schnell; passt zu Apple-Silicon-Mac + arm64-Sim).
# Universelle Slices: BUILD_X86_64=1 ./scripts/build-libssh2-xcframework.sh
#
set -euo pipefail

OPENSSL_VERSION="${OPENSSL_VERSION:-3.6.1}"
LIBSSH2_VERSION="${LIBSSH2_VERSION:-1.11.1}"

IOS_MIN="${IOS_MIN:-26.0}"
MACOS_MIN="${MACOS_MIN:-14.0}"
BUILD_X86_64="${BUILD_X86_64:-0}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/build/xcframework-work"
OUT="$ROOT/Vendor"
SRC="$WORK/src"
LOG="$WORK/logs"
mkdir -p "$WORK" "$SRC" "$LOG" "$OUT"

# slice = "<platform>:<arch>:<sdk>:<min-flag>"
SLICES=(
  "macos:arm64:macosx:-mmacosx-version-min=$MACOS_MIN"
  "iphoneos:arm64:iphoneos:-mios-version-min=$IOS_MIN"
  "iphonesimulator:arm64:iphonesimulator:-mios-simulator-version-min=$IOS_MIN"
)
if [[ "$BUILD_X86_64" == "1" ]]; then
  SLICES+=(
    "macos:x86_64:macosx:-mmacosx-version-min=$MACOS_MIN"
    "iphonesimulator:x86_64:iphonesimulator:-mios-simulator-version-min=$IOS_MIN"
  )
fi

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFEHLER:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Quellen laden
# ---------------------------------------------------------------------------
fetch() {
  local url="$1" out="$2"
  [[ -f "$out" ]] && return 0
  log "Lade $(basename "$out")"
  curl -fL --retry 3 -o "$out" "$url" || fail "Download fehlgeschlagen: $url"
}

OPENSSL_TARBALL="$SRC/openssl-$OPENSSL_VERSION.tar.gz"
LIBSSH2_TARBALL="$SRC/libssh2-$LIBSSH2_VERSION.tar.gz"
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" "$OPENSSL_TARBALL"
fetch "https://github.com/libssh2/libssh2/releases/download/libssh2-$LIBSSH2_VERSION/libssh2-$LIBSSH2_VERSION.tar.gz" "$LIBSSH2_TARBALL"

# ---------------------------------------------------------------------------
# OpenSSL Configure-Target je Slice
# ---------------------------------------------------------------------------
openssl_target() {
  case "$1:$2" in
    macos:arm64)            echo "darwin64-arm64-cc" ;;
    macos:x86_64)           echo "darwin64-x86_64-cc" ;;
    iphoneos:arm64)         echo "ios64-xcrun" ;;
    iphonesimulator:arm64)  echo "iossimulator-arm64-xcrun" ;;
    iphonesimulator:x86_64) echo "iossimulator-x86_64-xcrun" ;;
    *) fail "Unbekannter OpenSSL-Slice $1:$2" ;;
  esac
}

build_openssl() {
  local platform="$1" arch="$2" sdk="$3" minflag="$4"
  local prefix="$WORK/openssl/$platform-$arch"
  [[ -f "$prefix/lib/libssl.a" && -f "$prefix/lib/libcrypto.a" ]] && { log "OpenSSL $platform-$arch bereits gebaut"; return 0; }

  local dir="$WORK/openssl/build-$platform-$arch"
  rm -rf "$dir"; mkdir -p "$dir"
  tar xf "$OPENSSL_TARBALL" -C "$dir" --strip-components=1

  local target; target="$(openssl_target "$platform" "$arch")"

  # Arch + isysroot stecken bereits im Target (darwin64-<arch>-cc / *-xcrun) —
  # nur das Deployment-Target-Flag als zusätzlichen Compiler-Flag anhängen.
  log "OpenSSL $platform-$arch ($target)"
  (
    cd "$dir"
    ./Configure "$target" no-shared no-tests no-asm no-engine no-dso no-legacy \
      --prefix="$prefix" \
      $minflag >/dev/null
    make -j"$(sysctl -n hw.ncpu)" build_libs >/dev/null
    make install_dev >/dev/null
  ) >"$LOG/openssl-$platform-$arch.log" 2>&1 || fail "OpenSSL $platform-$arch (siehe $LOG/openssl-$platform-$arch.log)"
}

# ---------------------------------------------------------------------------
# libssh2 via CMake (umgeht autoconf), statisch, gegen obiges OpenSSL
# ---------------------------------------------------------------------------
build_libssh2() {
  local platform="$1" arch="$2" sdk="$3" minflag="$4"
  local ossl="$WORK/openssl/$platform-$arch"
  local prefix="$WORK/libssh2/$platform-$arch"
  [[ -f "$prefix/lib/libssh2.a" ]] && { log "libssh2 $platform-$arch bereits gebaut"; return 0; }

  local dir="$WORK/libssh2/build-$platform-$arch"
  rm -rf "$dir"; mkdir -p "$dir/src"
  tar xf "$LIBSSH2_TARBALL" -C "$dir/src" --strip-components=1

  local sysroot; sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  local minver="${minflag##*=}"
  local cmake_sysname cmake_sysroot_arg=()
  if [[ "$sdk" == macosx ]]; then
    cmake_sysname="Darwin"
  else
    cmake_sysname="iOS"
  fi

  log "libssh2 $platform-$arch"
  (
    cmake -S "$dir/src" -B "$dir/out" -G "Unix Makefiles" \
      -DCMAKE_SYSTEM_NAME="$cmake_sysname" \
      -DCMAKE_OSX_SYSROOT="$sysroot" \
      -DCMAKE_OSX_ARCHITECTURES="$arch" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$minver" \
      -DCMAKE_INSTALL_PREFIX="$prefix" \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=OFF \
      -DBUILD_EXAMPLES=OFF \
      -DBUILD_TESTING=OFF \
      -DCRYPTO_BACKEND=OpenSSL \
      -DOPENSSL_ROOT_DIR="$ossl" \
      -DOPENSSL_USE_STATIC_LIBS=ON \
      -DOPENSSL_INCLUDE_DIR="$ossl/include" \
      -DOPENSSL_CRYPTO_LIBRARY="$ossl/lib/libcrypto.a" \
      -DOPENSSL_SSL_LIBRARY="$ossl/lib/libssl.a" >/dev/null
    cmake --build "$dir/out" --target install -j"$(sysctl -n hw.ncpu)" >/dev/null
  ) >"$LOG/libssh2-$platform-$arch.log" 2>&1 || fail "libssh2 $platform-$arch (siehe $LOG/libssh2-$platform-$arch.log)"
}

# ---------------------------------------------------------------------------
# Pro Slice bauen
# ---------------------------------------------------------------------------
for slice in "${SLICES[@]}"; do
  IFS=":" read -r platform arch sdk minflag <<< "$slice"
  build_openssl "$platform" "$arch" "$sdk" "$minflag"
  build_libssh2 "$platform" "$arch" "$sdk" "$minflag"
done

# ---------------------------------------------------------------------------
# Pro Plattform: Architekturen mit lipo zusammenführen, OpenSSL mergen
# ---------------------------------------------------------------------------
platforms_seen=()
for slice in "${SLICES[@]}"; do
  IFS=":" read -r platform _ _ _ <<< "$slice"
  [[ " ${platforms_seen[*]:-} " == *" $platform "* ]] || platforms_seen+=("$platform")
done

STAGE="$WORK/stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
for platform in "${platforms_seen[@]}"; do
  archs=()
  for slice in "${SLICES[@]}"; do
    IFS=":" read -r p a _ _ <<< "$slice"
    [[ "$p" == "$platform" ]] && archs+=("$a")
  done

  local_ossl_dir="$STAGE/openssl/$platform"; mkdir -p "$local_ossl_dir/lib"
  local_ssh2_dir="$STAGE/libssh2/$platform"; mkdir -p "$local_ssh2_dir/lib"

  # Header (architekturunabhängig) vom ersten Arch übernehmen
  cp -R "$WORK/openssl/$platform-${archs[0]}/include" "$local_ossl_dir/include"
  cp -R "$WORK/libssh2/$platform-${archs[0]}/include" "$local_ssh2_dir/include"

  # CSSH-Clang-Modul in die libssh2-Header legen, damit Swift `import CSSH`
  # auflöst (entspricht Shouts ursprünglichem systemLibrary-Modul, nur ohne
  # `[system]`/`link` — gelinkt wird die statische lib aus dem xcframework).
  cat > "$local_ssh2_dir/include/shim.h" <<'EOF'
#ifndef __CLIBSSH_SHIM_H__
#define __CLIBSSH_SHIM_H__
#include <libssh2.h>
#include <libssh2_sftp.h>
#include <libssh2_publickey.h>
#endif
EOF
  cat > "$local_ssh2_dir/include/module.modulemap" <<'EOF'
module CSSH {
  header "shim.h"
  export *
}
EOF

  # je Arch libssl+libcrypto zu libopenssl.a mergen
  merged=()
  for a in "${archs[@]}"; do
    libtool -static -o "$WORK/openssl/$platform-$a/lib/libopenssl.a" \
      "$WORK/openssl/$platform-$a/lib/libssl.a" \
      "$WORK/openssl/$platform-$a/lib/libcrypto.a" 2>/dev/null
    merged+=("$WORK/openssl/$platform-$a/lib/libopenssl.a")
  done
  lipo -create "${merged[@]}" -output "$local_ossl_dir/lib/libopenssl.a"

  ssh2_libs=()
  for a in "${archs[@]}"; do ssh2_libs+=("$WORK/libssh2/$platform-$a/lib/libssh2.a"); done
  lipo -create "${ssh2_libs[@]}" -output "$local_ssh2_dir/lib/libssh2.a"
done

# ---------------------------------------------------------------------------
# xcframeworks erzeugen
# ---------------------------------------------------------------------------
make_xcframework() {
  local name="$1" libname="$2"
  local args=()
  for platform in "${platforms_seen[@]}"; do
    args+=(-library "$STAGE/$name/$platform/lib/$libname" -headers "$STAGE/$name/$platform/include")
  done
  rm -rf "$OUT/$name.xcframework"
  xcodebuild -create-xcframework "${args[@]}" -output "$OUT/$name.xcframework" >/dev/null
}

log "Erzeuge xcframeworks"
make_xcframework openssl libopenssl.a
make_xcframework libssh2 libssh2.a

log "Fertig:"
echo "  $OUT/openssl.xcframework"
echo "  $OUT/libssh2.xcframework"
plutil -p "$OUT/libssh2.xcframework/Info.plist" 2>/dev/null | grep -E "LibraryIdentifier|SupportedPlatform|SupportedArchitectures" || true
