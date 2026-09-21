#!/usr/bin/env bash
# Install verified releases privately; no system services or global configuration.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HERE/.runtime/tools"
mkdir -p "$DEST"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) platform=darwin-arm64; checksum=ec6ea5c92a764893dbaa50e12994ef2706145e238c9854b1e37168d9d2c862a6 ;;
  Darwin-x86_64) platform=darwin-amd64; checksum=ebe3c181dd2af667980c0e51a1daff7d8131b632351fba7970b226fb7527b7aa ;;
  Linux-x86_64) platform=linux-amd64; checksum=3694ea4e1044b367e1c21ffe28117f209c5989fa5e604d000321809f871ab701 ;;
  Linux-aarch64) platform=linux-arm64; checksum=fbeaf099b7c90b8b83dfa4781601c1181d8d06e89af34b846680c86ce08f725c ;;
  *) echo 'Unsupported platform' >&2; exit 1 ;;
esac
verify() {
  python3 - "$1" "$2" <<'PY'
import hashlib, pathlib, sys
if hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest() != sys.argv[2]:
    sys.exit('Release checksum mismatch')
PY
}
curl --fail --silent --show-error --location --retry 3 \
  "https://github.com/grafana/alloy/releases/download/v1.19.2/alloy-${platform}.zip" -o "$WORK/alloy.zip"
verify "$WORK/alloy.zip" "$checksum"
unzip -q "$WORK/alloy.zip" -d "$WORK"
install -m 755 "$WORK/alloy-${platform}" "$DEST/alloy"
curl --fail --silent --show-error --location --retry 3 \
  https://nginx.org/download/nginx-1.30.5.tar.gz -o "$WORK/nginx.tar.gz"
verify "$WORK/nginx.tar.gz" 6c20565aa2325cb82216ae804f4a4ff1875179014759a381c42ddc8e11c4906d
tar -xzf "$WORK/nginx.tar.gz" -C "$WORK"
cd "$WORK/nginx-1.30.5"
EXTRA=()
if [[ "$(uname -s)" == Darwin ]]; then
  OPENSSL_PREFIX="$(brew --prefix openssl@3)"
  PCRE_PREFIX="$(brew --prefix pcre2)"
  EXTRA=("--with-cc-opt=-I${OPENSSL_PREFIX}/include -I${PCRE_PREFIX}/include" "--with-ld-opt=-L${OPENSSL_PREFIX}/lib -L${PCRE_PREFIX}/lib")
fi
./configure --prefix="$DEST/nginx-install" --with-http_ssl_module \
  --without-http_gzip_module "${EXTRA[@]}" > "$WORK/configure.log" 2>&1 || { cat "$WORK/configure.log"; exit 1; }
make -j2 > "$WORK/make.log" 2>&1 || { tail -80 "$WORK/make.log"; exit 1; }
install -m 755 objs/nginx "$DEST/nginx"
echo "Installed Alloy 1.19.2 and nginx 1.30.5 in $DEST"
