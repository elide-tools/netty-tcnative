#!/usr/bin/env bash
# stage-natives-tcnative.sh — build netty-tcnative native + static-archive
# JARs for one platform target and stage them in Maven repo layout under a
# local directory. Sibling to stage-natives.sh (which handles netty itself).
#
# Unlike netty (where one Maven `-P<profile>` covers all modules for a given
# host), tcnative's modules use module-specific profile names: openssl-static
# uses `build-openssl-mac` / `build-openssl-linux`, libressl-static uses
# `build-libressl-non-windows`, boringssl-static uses `boringssl-static-default`,
# etc. So this script accepts a higher-level `<platform>` argument and maps it
# to the per-module profile per the table below.

set -euo pipefail

# Default TCNATIVE_DIR resolution (in priority order):
#   1. Explicit TCNATIVE_DIR env var.
#   2. Parent of script dir, IF that parent has mvnw (script lives in netty-tcnative/scripts/).
#   3. Sibling "netty-tcnative" directory next to the script's repo.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_parent="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -n "${TCNATIVE_DIR:-}" ]]; then
  :
elif [[ -x "$script_parent/mvnw" ]]; then
  TCNATIVE_DIR="$script_parent"
elif [[ -x "$script_parent/../netty-tcnative/mvnw" ]]; then
  TCNATIVE_DIR="$(cd "$script_parent/../netty-tcnative" && pwd)"
else
  TCNATIVE_DIR="$script_parent"
fi

usage() {
  cat <<EOF
Usage: $0 <stage-dir> <platform> [--prep-deps]

  <stage-dir>    Absolute path to a writable directory. Created if missing.
                 Native + static JARs land in Maven repo layout under it.
  <platform>     One of:
                   mac-aarch64    | mac-x86_64
                   linux-x86_64   | linux-aarch64
                 (Windows static archives are deferred — see netty-static-jni
                 specs for the follow-up plan.)
  --prep-deps    Install the openssl-classes Java-only sibling to ~/.m2.
                 Run once per branch update.

Environment:
  TCNATIVE_DIR   Path to the netty-tcnative checkout. Default: $TCNATIVE_DIR

Per-platform module → profile mapping:

  mac-aarch64:
    openssl-dynamic   → mac-aarch64
    boringssl-static  → boringssl-static-default
    openssl-static    → build-openssl-mac
    libressl-static   → build-libressl-non-windows

  mac-x86_64:
    openssl-dynamic   → mac-x86_64
    boringssl-static  → mac-intel-cross-compile
    openssl-static    → build-openssl-mac
    libressl-static   → build-libressl-non-windows

  linux-x86_64:
    openssl-dynamic   → (default — no -P)
    boringssl-static  → boringssl-static-default
    openssl-static    → build-openssl-linux
    libressl-static   → build-libressl-non-windows

  linux-aarch64:
    openssl-dynamic   → linux-aarch64
    boringssl-static  → linux-aarch64
    openssl-static    → build-openssl-linux
    libressl-static   → build-libressl-non-windows
EOF
}

if [[ $# -lt 2 ]]; then
  usage >&2
  exit 1
fi

STAGE="$1"
PLATFORM="$2"
shift 2

PREP=0
for arg in "$@"; do
  case "$arg" in
    --prep-deps) PREP=1 ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "Unknown arg: $arg" >&2; usage >&2; exit 1 ;;
  esac
done

# Per-platform per-module build entries. Each entry is "module:profile".
# A trailing colon (`module:`) means "no -P flag" (default activation).
case "$PLATFORM" in
  mac-aarch64)
    BUILDS=(
      "openssl-dynamic:mac-aarch64"
      "boringssl-static:boringssl-static-default"
      "openssl-static:build-openssl-mac"
      "libressl-static:build-libressl-non-windows"
    )
    ;;
  mac-x86_64)
    BUILDS=(
      "openssl-dynamic:mac-x86_64"
      "boringssl-static:mac-intel-cross-compile"
      "openssl-static:build-openssl-mac"
      "libressl-static:build-libressl-non-windows"
    )
    ;;
  linux-x86_64)
    BUILDS=(
      "openssl-dynamic:"
      "boringssl-static:boringssl-static-default"
      "openssl-static:build-openssl-linux"
      "libressl-static:build-libressl-non-windows"
    )
    ;;
  linux-aarch64)
    BUILDS=(
      "openssl-dynamic:linux-aarch64"
      "boringssl-static:linux-aarch64"
      "openssl-static:build-openssl-linux"
      "libressl-static:build-libressl-non-windows"
    )
    ;;
  *)
    echo "Unknown platform: $PLATFORM" >&2
    usage >&2
    exit 1
    ;;
esac

# Canonicalize STAGE so altDeploymentRepository receives an absolute file URL.
mkdir -p "$STAGE"
STAGE="$(cd "$STAGE" && pwd)"

if [[ ! -d "$TCNATIVE_DIR" ]]; then
  echo "TCNATIVE_DIR not found: $TCNATIVE_DIR" >&2
  exit 1
fi

cd "$TCNATIVE_DIR"

if [[ ! -x ./mvnw ]]; then
  echo "Maven wrapper not found at $TCNATIVE_DIR/mvnw" >&2
  exit 1
fi

# Skip checkstyle/nohttp/forbiddenapis/revapi across the board: this is a
# downstream staging path, not a release; tcnative's release-flavored quality
# checks otherwise gate the build on URL/policy concerns that don't matter for
# binary staging.
SKIP_FLAGS=(
  -Dcheckstyle.skip=true
  -Dnohttp.skip=true
  -Dforbiddenapis.skip=true
  -Drevapi.skip=true
)

if [[ "$PREP" == 1 ]]; then
  echo "==> Installing openssl-classes (Java-only sibling) to ~/.m2"
  ./mvnw install -DskipTests -q "${SKIP_FLAGS[@]}" -pl 'openssl-classes'
fi

# id::layout::url — the legacy 3-token form is required by maven-deploy-plugin
# 2.x, which tcnative pins. Newer (3.x) accepts both.
DEPLOY_REPO="local::default::file://$STAGE"

for build in "${BUILDS[@]}"; do
  module="${build%%:*}"
  profile="${build#*:}"
  display_profile="${profile:-default}"
  echo "==> Staging $module (platform=$PLATFORM, profile=$display_profile) → $STAGE"
  (
    cd "$module"
    if [[ -n "$profile" ]]; then
      ../mvnw "-P$profile" clean deploy -DskipTests -q "${SKIP_FLAGS[@]}" \
        "-DaltDeploymentRepository=$DEPLOY_REPO"
    else
      ../mvnw clean deploy -DskipTests -q "${SKIP_FLAGS[@]}" \
        "-DaltDeploymentRepository=$DEPLOY_REPO"
    fi
  )
done

echo
echo "==> Staged artifacts under $STAGE/io/netty:"
find "$STAGE/io/netty" -type f \( -name "*.jar" -o -name "*.pom" \) 2>/dev/null \
  | sort \
  | sed "s|^$STAGE/||"
