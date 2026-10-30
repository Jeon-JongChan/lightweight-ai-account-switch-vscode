#!/usr/bin/env bash
# Rust - 독립 실행 스크립트 (Linux, Facade 4-액션 내장).
# 이 파일 하나만 복사해도 설치·환경설정(검증/세션/전역/prime/offline-check/tauri)·최신화·초기화가 모두 동작한다.
#   대화형 메뉴: bash rust.sh
#   비대화형:    bash rust.sh install | configure --mode verify|env|global-on|global-off|prime|offline-check|list|run | update | reset --yes
#   세션 적용:   source rust.sh
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LANG_NAME=rust
STATE="$ROOT/$LANG_NAME/_state"
pbk_path() { local p; for p in "$@"; do if [[ -d "$p" ]]; then chmod +x "$p"/* 2>/dev/null || true; PATH="$p:$PATH"; fi; done; export PATH; }
activate() {
 export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
 export RUSTUP_HOME="$ROOT/rust/rustup" CARGO_HOME="$ROOT/rust/cargo"
 export npm_config_cache="$ROOT/nodejs/npm-cache" npm_config_prefix="$ROOT/nodejs/npm-global" npm_config_userconfig="$ROOT/nodejs/npmrc" COREPACK_HOME="$ROOT/nodejs/corepack" npm_config_update_notifier=false npm_config_unsafe_perm=true
 pbk_path "$ROOT/rust/cargo/bin" "$ROOT/nodejs/node/bin"
}
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
 activate; unset -f activate pbk_path; unset ROOT LANG_NAME STATE
 return 0
fi
set -euo pipefail
log() { printf '[build-kit] %s\n' "$*"; }
fail() { echo "[build-kit] ERROR: $*" >&2; exit 1; }
requires() { command -v "$1" >/dev/null 2>&1 || fail "Host command missing: $1"; }
# 쓰기 권한을 복구할 수 없으면 기존 폴더를 보존하고 중단합니다.
ensure_dir() {
 local d="$1"
 if [[ -d "$d" && ! -w "$d" ]]; then chmod -R u+rwX "$d" 2>/dev/null || fail "Cannot restore directory permissions: $d"; fi
 mkdir -p "$d" 2>/dev/null || fail "Cannot create or write directory: $d"
 [[ -w "$d" ]] || fail "Cannot write directory: $d"
}
rm_tree() {
 local d="$1"
 [[ -e "$d" || -L "$d" ]] || return 0
 chmod -R u+rwX "$d" 2>/dev/null || true
 rm -rf -- "$d"
}
case "$(uname -s)" in Linux) ;; *) fail 'This .sh supports Linux. For Windows use rust.ps1.';; esac
case "$(uname -m)" in x86_64|amd64) host_arch=x64; rust_arch=x86_64;; aarch64|arm64) host_arch=aarch64; rust_arch=aarch64;; *) fail "Unsupported CPU $(uname -m)";; esac
fetch() { requires curl; ensure_dir "$(dirname "$2")"; curl --fail --location --retry 3 --connect-timeout 20 --output "$2" "$1"; }
sha_check() {
 local file="$1" expected="$2" actual
 requires sha256sum
 actual="$(sha256sum "$file" | awk '{print $1}')"
 [[ "${actual,,}" == "${expected,,}" ]] || fail "SHA256 mismatch: $file"
}
extract_one() {
 local archive="$1" into="$2" staging="$STATE/extract.$$"
 ensure_dir "$staging"; ensure_dir "$into"
 if [[ "$archive" == *.zip ]]; then requires unzip; unzip -q -o "$archive" -d "$staging" || fail "Cannot extract $archive"; else requires tar; tar --no-same-owner --no-same-permissions -xf "$archive" -C "$staging" || fail "Cannot extract $archive"; fi
 local dirs=("$staging"/*) src="$staging"
 if [[ ${#dirs[@]} -eq 1 && -d ${dirs[0]} ]]; then src="${dirs[0]}"; fi
 cp -RP --preserve=mode,links "$src/." "$into/" 2>/dev/null || cp -R "$src/." "$into/" || fail "Cannot copy into $into"
 chmod -R u+rwX "$into" 2>/dev/null || true
 rm_tree "$staging"
}

DEFAULT_PROJECT="$ROOT"; [[ "$(basename "$ROOT")" == ".build" ]] && DEFAULT_PROJECT="$(dirname "$ROOT")"
ACTION=menu MODE=verify FEATURE=none OPERATION= SCOPE=all YES=0 PROJECT="$DEFAULT_PROJECT"
NODE_MAJOR=24 WITH_NDK=0 RUN_ARGS=()
while (($#)); do
 case "$1" in
  menu|install|configure|update|reset|verify|prime|offline-check|env|global-on|global-off|remove|list|run|tauri-install|tauri-verify|tauri-prime|tauri-offline-check|tauri-remove) ACTION="$1"; shift;;
  --mode) MODE="${2:?}"; shift 2;;
  --feature) FEATURE="${2:?}"; shift 2;;
  --operation) OPERATION="${2:?}"; shift 2;;
  --scope) SCOPE="${2:?}"; shift 2;;
  --yes) YES=1; shift;;
  --project) PROJECT="${2:?}"; shift 2;;
  --node-major) NODE_MAJOR="${2:?}"; shift 2;;
  --with-ndk) WITH_NDK=1; shift;;
  --accept-android-licenses) shift;;
  --) shift; RUN_ARGS=("$@"); break;;
  -h|--help) echo "Usage: bash $LANG_NAME.sh [menu|install|configure|update|reset|tauri-*] [options]"; exit 0;;
  *) fail "Unknown option or action: $1";;
 esac
done
PROJECT="$(cd "$PROJECT" 2>/dev/null && pwd)" || fail "Project directory does not exist: $PROJECT"

project_ref() {
 local base="$DEFAULT_PROJECT"
 if [[ "$PROJECT" == "$base" ]]; then printf '.'
 elif [[ "$PROJECT" == "$base/"* ]]; then printf '%s' "${PROJECT#"$base/"}"
 else printf '%s' "$PROJECT"; fi
}
project_key() { project_ref | sha256sum | cut -c1-12; }
project_rust_target() { printf '%s/rust/targets/%s' "$ROOT" "$(project_key)"; }

install_rust() {
 [[ -x "$ROOT/rust/cargo/bin/cargo" ]] && { log 'rust already present'; return; }
 local uri="https://static.rust-lang.org/rustup/dist/${rust_arch}-unknown-linux-gnu/rustup-init" tmp="$STATE/rustup-init" expected
 fetch "$uri.sha256" "$tmp.sha256"; expected="$(awk '{print $1}' "$tmp.sha256")"
 [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || fail 'Rustup hash unavailable'
 fetch "$uri" "$tmp"; sha_check "$tmp" "$expected"; chmod +x "$tmp"
 activate; RUSTUP_INIT_SKIP_PATH_CHECK=yes "$tmp" -y --no-modify-path --profile minimal --default-toolchain stable
 rm -f "$tmp" "$tmp.sha256"
 if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
  log 'WARNING: no system C linker (cc/gcc). rustc installs, but cargo build needs build-essential (or equivalent).'
 fi
}
install_nodejs_shared() {
 if [[ -x "$ROOT/nodejs/node/bin/node" ]]; then return; fi
 if [[ -f "$ROOT/nodejs.sh" ]]; then bash "$ROOT/nodejs.sh" install --node-major "$NODE_MAJOR"; return; fi
 local sums filename expected tmp
 sums="$(curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/SHASUMS256.txt")"
 filename="$(printf '%s\n' "$sums" | awk -v m="$NODE_MAJOR" -v a="$([[ "$host_arch" == x64 ]] && echo x64 || echo arm64)" '$2 ~ ("^node-v" m "[.]" ) && $2 ~ ("-linux-" a "[.]tar[.]gz$") {print $2;exit}')"
 [[ -n "$filename" ]] || fail "No Node LTS archive for Linux $host_arch"
 expected="$(printf '%s\n' "$sums" | awk -v f="$filename" '$2==f {print $1;exit}')"
 tmp="$STATE/$filename"; fetch "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/$filename" "$tmp"; sha_check "$tmp" "$expected"
 ensure_dir "$ROOT/nodejs/node"; extract_one "$tmp" "$ROOT/nodejs/node"; rm -f "$tmp"
}
do_verify() { [[ -x "$ROOT/rust/cargo/bin/rustc" ]] && rustc --version || fail 'Rust verification failed'; }
do_update() {
 [[ -x "$ROOT/rust/cargo/bin/rustup" ]] || fail 'Rust missing. Run install first.'
 activate; rustup set profile minimal; rustup update stable
}
do_prime() {
 [[ -x "$ROOT/rust/cargo/bin/cargo" ]] || fail 'Rust missing'
 [[ -f "$PROJECT/Cargo.toml" ]] || fail 'Cargo.toml missing'
 (cd "$PROJECT" && CARGO_TARGET_DIR="$(project_rust_target)" cargo fetch && CARGO_TARGET_DIR="$(project_rust_target)" cargo build)
}
do_offline() {
 [[ -x "$ROOT/rust/cargo/bin/cargo" ]] || fail 'Rust missing'
 [[ -f "$PROJECT/Cargo.toml" ]] || fail 'Cargo.toml missing'
 (cd "$PROJECT" && CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$(project_rust_target)" cargo build --offline)
}
install_tauri() {
 install_rust; install_nodejs_shared
 if ((WITH_NDK)); then
  [[ -f "$ROOT/kotlin.sh" ]] && bash "$ROOT/kotlin.sh" install --with-ndk
  activate; rustup target add aarch64-linux-android
 fi
 ensure_dir "$ROOT/rust/tauri"
 printf 'Tauri 2 is optional: Rust and Node.js are shared, project dependencies live in .build/nodejs/projects.\n' > "$ROOT/rust/tauri/README.txt"
 if ! command -v pkg-config >/dev/null || ! pkg-config --exists webkit2gtk-4.1 2>/dev/null; then
  log 'WARNING: Tauri Linux host dependencies missing (WebKitGTK 4.1 etc.). See official Tauri prerequisites.'
 fi
}
verify_tauri() {
 do_verify
 [[ -x "$ROOT/nodejs/node/bin/node" ]] && "$ROOT/nodejs/node/bin/node" --version && "$ROOT/nodejs/node/bin/npm" --version || fail 'Node.js verification failed'
 command -v pkg-config >/dev/null || fail 'Tauri requires host pkg-config'
 pkg-config --exists webkit2gtk-4.1 || fail 'Tauri requires host WebKitGTK 4.1 development libraries'
 pkg-config --exists openssl || fail 'Tauri requires host OpenSSL development libraries'
 requires cc
 log 'Host prerequisites partially checked; real bundling/targets still require project build tests.'
}
prime_tauri() {
 [[ -f "$PROJECT/src-tauri/Cargo.toml" ]] || fail 'src-tauri/Cargo.toml missing'
 if [[ -f "$ROOT/nodejs.sh" ]]; then
  if [[ "${1:-online}" == offline ]]; then bash "$ROOT/nodejs.sh" configure --mode offline-check --project "$PROJECT"
  else bash "$ROOT/nodejs.sh" configure --mode prime --project "$PROJECT"; fi
 else
  if [[ "${1:-online}" == offline ]]; then (cd "$PROJECT" && npm_config_offline=true npm run build --if-present)
  else (cd "$PROJECT" && npm ci --include=optional && npm run build --if-present); fi
 fi
 if [[ "${1:-online}" == offline ]]; then
  (cd "$PROJECT/src-tauri" && CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$(project_rust_target)" cargo build --offline)
 else
  (cd "$PROJECT/src-tauri" && CARGO_TARGET_DIR="$(project_rust_target)" cargo fetch && CARGO_TARGET_DIR="$(project_rust_target)" cargo build)
 fi
}
global_on() {
 local rc="$HOME/.bashrc" mark="# >>> portable-build-kit ($LANG_NAME) >>>" end="# <<< portable-build-kit ($LANG_NAME) <<<"
 ensure_dir "$STATE"
 [[ ! -f "$STATE/global-bash-enabled" ]] || { log 'Already registered in ~/.bashrc'; return; }
 [[ -e "$rc" ]] || : > "$rc"
 printf '\n%s\nsource %q\n%s\n' "$mark" "$ROOT/$LANG_NAME.sh" "$end" >> "$rc"
 printf '%s\n' "$rc" > "$STATE/global-bash-enabled"
 log "Registered $LANG_NAME in $rc."
}
global_off() {
 local marker="$STATE/global-bash-enabled" rc mark="# >>> portable-build-kit ($LANG_NAME) >>>" end="# <<< portable-build-kit ($LANG_NAME) <<<"
 [[ -f "$marker" ]] || { log 'No managed Bash shell profile registration'; return; }
 rc="$(cat "$marker")"; [[ -f "$rc" ]] || { rm -f "$marker"; return; }
 local tmp="$STATE/bashrc.$$"
 awk -v m="$mark" -v e="$end" '$0==m {skip=1;next} $0==e {skip=0;next} !skip {print}' "$rc" > "$tmp"
 cat "$tmp" > "$rc"; rm -f "$tmp" "$marker"
 log 'Removed managed shell profile block.'
}
do_list() {
 local l; for l in go rust kotlin csharp nodejs python; do
  if [[ -d "$ROOT/$l" ]]; then printf '%-8s installed\n' "$l"; else printf '%-8s absent\n' "$l"; fi
 done
}
menu() {
 local n sub confirm choice
 echo "=== Portable Build Kit: ${LANG_NAME} ==="
 echo '1. 설치 (Install)'
 echo '2. 환경설정 (Configure)'
 echo '3. 최신화 (Update)'
 echo '4. 초기화 (Reset)'
 echo '0. 종료'
 read -r -p 'Choose: ' n
 case "$n" in
  1) ACTION=install;;
  2)
   ACTION=configure
   echo 'Configuration: 1 verify | 2 session env | 3 global-on | 4 global-off'
   echo '               5 prime dependencies | 6 offline-check | 7 list | 8 optional features | 0 back'
   read -r -p 'Choice: ' sub
   case "$sub" in
    1) MODE=verify;;2) MODE=env;;3) MODE=global-on;;4) MODE=global-off;;5) MODE=prime;;6) MODE=offline-check;;7) MODE=list;;
    8)
     echo 'Tauri 2: 1 install | 2 verify | 3 prime | 4 offline-check | 5 remove | 0 back'
     read -r -p 'Choice: ' choice
     case "$choice" in 1) OPERATION=install;;2) OPERATION=verify;;3) OPERATION=prime;;4) OPERATION=offline-check;;5) OPERATION=remove;;0) exit 0;;*) fail 'Invalid Tauri choice';; esac
     FEATURE=tauri;;
    0) exit 0;;
    *) fail 'Invalid config choice';;
   esac;;
  3) ACTION=update;;
  4)
   ACTION=reset
   echo 'Reset: 1 restore environment + delete managed tools | 2 restore environment only | 3 delete tools only | 0 back'
   read -r -p 'Choice: ' sub
   case "$sub" in 1) SCOPE=all;;2) SCOPE=env;;3) SCOPE=tools;;0) exit 0;;*) fail 'Invalid reset choice';; esac
   read -r -p "Confirm reset [$LANG_NAME/$SCOPE] (type RESET): " confirm
   [[ "$confirm" == RESET ]] || { log 'Cancelled'; exit 0; }
   YES=1;;
  0) exit 0;;
  *) fail 'Invalid menu choice';;
 esac
}
if [[ "$ACTION" == menu ]]; then menu; fi
if [[ "$ACTION" == configure ]]; then
 if [[ "$FEATURE" == tauri ]]; then ACTION="tauri-${OPERATION}"
 elif [[ "$FEATURE" != none ]]; then fail "Unsupported feature for $LANG_NAME: $FEATURE"
 else ACTION="$MODE"; fi
fi
case "$ACTION" in
 install) install_rust;;
 verify) activate; do_verify;;
 update) do_update;;
 prime) activate; do_prime;;
 offline-check) activate; do_offline;;
 env) printf 'Run in current shell: source %q\n' "$ROOT/$LANG_NAME.sh";;
 global-on) global_on;;
 global-off) global_off;;
 list) do_list;;
 tauri-install) install_tauri;;
 tauri-verify) activate; verify_tauri;;
 tauri-prime) activate; prime_tauri online;;
 tauri-offline-check) activate; prime_tauri offline;;
 tauri-remove) rm_tree "$ROOT/rust/tauri"; log 'Removed optional Tauri marker; shared tools/caches preserved';;
 reset|remove)
  if [[ "$ACTION" == reset && "$SCOPE" != env && "$YES" != 1 ]]; then fail 'Reset deletes toolchains; pass --yes after reviewing scope.'; fi
  case "$SCOPE" in
   all) global_off;;
   env) global_off; exit 0;;
   tools) [[ ! -f "$STATE/global-bash-enabled" ]] || fail 'Restore globals first or use --scope all';;
   *) fail 'Invalid reset scope';;
  esac
  rm_tree "$ROOT/$LANG_NAME"; log "Removed $LANG_NAME";;
 run) activate; ((${#RUN_ARGS[@]})) || fail 'run requires -- command [args]'; "${RUN_ARGS[@]}";;
 *) fail "Unsupported action: $ACTION";;
esac
