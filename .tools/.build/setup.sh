#!/usr/bin/env bash
# Portable Build Kit - Linux x86_64/aarch64 (Android command-line tools: x86_64)
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ACTION=menu LANG_NAME=all MODE=verify FEATURE=none OPERATION= SCOPE=all GO_VERSION_EXPLICIT=0 CONFIRM_RESET=0 PROJECT="$(dirname "$ROOT")" ANDROID_API=36 BUILD_TOOLS=36.0.0
JDK_MAJOR=21 NDK_VERSION=27.2.12479018 WITH_NDK=0 WITH_ADB=0 ACCEPT_LICENSES=0
TASK=assembleDebug PYTHON_VERSION=3.13 GO_VERSION=1.27.2 NODE_MAJOR=24 DOTNET_CHANNEL=10.0
EMULATOR_ABI=x86_64 EMULATOR_FLAVOR=google_apis AVD_NAME=pbk_android EMULATOR_HEADLESS=0 PURGE_EMULATOR_PACKAGES=0
RUN_ARGS=()
usage() {
cat <<'EOF'
Usage: bash .build/setup.sh <action> [options] [-- command arguments]
Facade actions: menu | install | configure | update | reset
Advanced compatibility: verify | prime | offline-check | env | global-on | global-off | remove | list | run
         vue-init | tauri-install | tauri-verify | tauri-prime | tauri-offline-check | tauri-remove
         emulator-install | emulator-list | emulator-start | emulator-remove
Facade options: --mode verify|env|global-on|global-off|prime|offline-check|list|run
                --feature emulator|tauri|vue --operation install|list|start|remove|verify|prime|offline-check|init
                --scope all|env|tools (for reset), --yes to authorize deletion
Options: --language go|rust|kotlin|csharp|nodejs|python|all
         --project PATH  --android-api N  --build-tools VERSION
         --with-ndk --ndk-version VERSION --with-adb --accept-android-licenses
         --emulator-abi x86_64|arm64-v8a --emulator-flavor default|google_apis
         --avd-name NAME --headless --purge-emulator-packages
         --task GradleTask --python-version N --go-version N --node-major N
         --dotnet-channel N
Examples:
 bash .build/setup.sh install --language kotlin --android-api 36 --accept-android-licenses
 bash .build/rust.sh tauri-install
 bash .build/nodejs.sh vue-init --project ./frontend
 bash .build/rust.sh tauri-prime --project ./frontend
 bash .build/setup.sh prime --language kotlin --project ./android --task assembleDebug
 bash .build/setup.sh run --language go -- go version
 source .build/env.sh   # active shell only; no user environment changes
EOF
}
while (($#)); do
 case "$1" in
  menu|install|configure|update|reset|verify|prime|offline-check|env|global-on|global-off|remove|list|run|vue-init|tauri-install|tauri-verify|tauri-prime|tauri-offline-check|tauri-remove|emulator-install|emulator-list|emulator-start|emulator-remove) ACTION="$1"; shift;;
  --mode) MODE="${2:?}"; shift 2;;
  --feature) FEATURE="${2:?}"; shift 2;;
  --operation) OPERATION="${2:?}"; shift 2;;
  --scope) SCOPE="${2:?}"; shift 2;;
  --yes) CONFIRM_RESET=1; shift;;
  --language|-l) LANG_NAME="${2:?}"; shift 2;;
  --project) PROJECT="${2:?}"; shift 2;;
  --android-api) ANDROID_API="${2:?}"; shift 2;;
  --build-tools) BUILD_TOOLS="${2:?}"; shift 2;;
  --ndk-version) NDK_VERSION="${2:?}"; shift 2;;
  --with-ndk) WITH_NDK=1; shift;;
  --with-adb) WITH_ADB=1; shift;;
  --emulator-abi) EMULATOR_ABI="${2:?}"; shift 2;;
  --emulator-flavor) EMULATOR_FLAVOR="${2:?}"; shift 2;;
  --avd-name) AVD_NAME="${2:?}"; shift 2;;
  --headless) EMULATOR_HEADLESS=1; shift;;
  --purge-emulator-packages) PURGE_EMULATOR_PACKAGES=1; shift;;
  --accept-android-licenses) ACCEPT_LICENSES=1; shift;;
  --task) TASK="${2:?}"; shift 2;;
  --jdk-major) JDK_MAJOR="${2:?}"; shift 2;;
  --python-version) PYTHON_VERSION="${2:?}"; shift 2;;
  --go-version) GO_VERSION="${2:?}"; GO_VERSION_EXPLICIT=1; shift 2;;
  --node-major) NODE_MAJOR="${2:?}"; shift 2;;
  --dotnet-channel) DOTNET_CHANNEL="${2:?}"; shift 2;;
  --) shift; RUN_ARGS=("$@"); break;;
  -h|--help) usage; exit 0;;
  *) echo "Unknown option: $1" >&2; usage; exit 2;;
 esac
done
case "$LANG_NAME" in all|go|rust|kotlin|csharp|nodejs|python) ;; *) echo "Invalid language: $LANG_NAME" >&2; exit 2;; esac
[[ "${ANDROID_API}" =~ ^[0-9]+$ && "${BUILD_TOOLS}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "${NDK_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid Android package version' >&2; exit 2; }
[[ "$EMULATOR_ABI" == x86_64 || "$EMULATOR_ABI" == arm64-v8a ]] || { echo 'Invalid emulator ABI' >&2; exit 2; }
[[ "$EMULATOR_FLAVOR" == default || "$EMULATOR_FLAVOR" == google_apis ]] || { echo 'Invalid emulator flavor' >&2; exit 2; }
[[ "$AVD_NAME" =~ ^[A-Za-z][A-Za-z0-9_.-]{0,63}$ ]] || { echo 'Invalid AVD name (ASCII letters/digits/._-)' >&2; exit 2; }
PROJECT="$(cd "$PROJECT" 2>/dev/null && pwd)" || { echo 'Project directory does not exist' >&2; exit 2; }
log() { printf '[build-kit] %s\n' "$*"; }
fail() { echo "[build-kit] ERROR: $*" >&2; exit 1; }
requires() { command -v "$1" >/dev/null 2>&1 || fail "Host command missing: $1"; }
# 다른 계정/컨테이너/외장 드라이브에서 실행 시 소유권·권한 불일치로 인한 실패 방지
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
ensure_dir "$ROOT/_state"
host_os=linux
case "$(uname -s)" in Linux) ;; *) fail 'This .sh installer currently supports Linux. For Windows use setup.ps1.';; esac
case "$(uname -m)" in x86_64|amd64) host_arch=x64; go_arch=amd64; rust_arch=x86_64;; aarch64|arm64) host_arch=aarch64; go_arch=arm64; rust_arch=aarch64;; *) fail "Unsupported CPU $(uname -m)";; esac
fetch() { requires curl; ensure_dir "$(dirname "$2")"; curl --fail --location --retry 3 --connect-timeout 20 --output "$2" "$1"; }
sha_check() {
 local file="$1" expected="$2" actual
 requires sha256sum
 actual="$(sha256sum "$file" | awk '{print $1}')"
 [[ "${actual,,}" == "${expected,,}" ]] || fail "SHA256 mismatch: $file"
}
extract_one() {
 local archive="$1" into="$2" staging="$ROOT/_state/extract.$$"
 ensure_dir "$staging"; ensure_dir "$into"
 # --no-same-owner/--no-same-permissions 및 cp --preserve=mode,links: root/컨테이너/마운트 볼륨에서 chown 실패 방지
 if [[ "$archive" == *.zip ]]; then requires unzip; unzip -q -o "$archive" -d "$staging" || fail "Cannot extract $archive"; else requires tar; tar --no-same-owner --no-same-permissions -xf "$archive" -C "$staging" || fail "Cannot extract $archive"; fi
 local dirs=("$staging"/*) src="$staging"
 if [[ ${#dirs[@]} -eq 1 && -d ${dirs[0]} ]]; then src="${dirs[0]}"; fi
 cp -RP --preserve=mode,links "$src/." "$into/" 2>/dev/null || cp -R "$src/." "$into/" || fail "Cannot copy into $into"
 chmod -R u+rwX "$into" 2>/dev/null || true
 rm_tree "$staging"
}
write_env() {
 cat > "$ROOT/env.sh" <<'EOF'
# Source only: source .build/env.sh
_PBK_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
export RUSTUP_HOME="$_PBK_ROOT/rust/rustup" CARGO_HOME="$_PBK_ROOT/rust/cargo"
export GOROOT="$_PBK_ROOT/go/sdk" GOPATH="$_PBK_ROOT/go/path" GOMODCACHE="$_PBK_ROOT/go/path/pkg/mod" GOCACHE="$_PBK_ROOT/go/cache" GOENV="$_PBK_ROOT/go/goenv" GOTOOLCHAIN=local
# ponytail: invariant avoids hard ICU dependency on minimal Linux; drop when full globalization needed
export DOTNET_ROOT="$_PBK_ROOT/csharp/dotnet" DOTNET_CLI_HOME="$_PBK_ROOT/csharp/home" NUGET_PACKAGES="$_PBK_ROOT/csharp/nuget" DOTNET_MULTILEVEL_LOOKUP=0 DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
export JAVA_HOME="$_PBK_ROOT/kotlin/jdk" ANDROID_HOME="$_PBK_ROOT/kotlin/android-sdk" ANDROID_SDK_ROOT="$_PBK_ROOT/kotlin/android-sdk" GRADLE_USER_HOME="$_PBK_ROOT/kotlin/gradle" ANDROID_USER_HOME="$_PBK_ROOT/kotlin/android-user" ANDROID_PREFS_ROOT="$_PBK_ROOT/kotlin/android-user" ANDROID_EMULATOR_HOME="$_PBK_ROOT/kotlin/android-user" ANDROID_AVD_HOME="$_PBK_ROOT/kotlin/android-user/avd"
# ponytail: UV_MANAGED_PYTHON conflicts with UV_PYTHON_PREFERENCE on uv>=0.13
export UV_CACHE_DIR="$_PBK_ROOT/python/cache" UV_PYTHON_INSTALL_DIR="$_PBK_ROOT/python/runtimes" UV_PYTHON_BIN_DIR="$_PBK_ROOT/python/bin" UV_PYTHON_PREFERENCE=only-managed UV_LINK_MODE=copy UV_TOOL_DIR="$_PBK_ROOT/python/tools" UV_TOOL_BIN_DIR="$_PBK_ROOT/python/bin" PIP_CACHE_DIR="$_PBK_ROOT/python/pip-cache" PYTHONNOUSERSITE=1
export npm_config_cache="$_PBK_ROOT/nodejs/npm-cache" npm_config_prefix="$_PBK_ROOT/nodejs/npm-global" npm_config_userconfig="$_PBK_ROOT/nodejs/npmrc" COREPACK_HOME="$_PBK_ROOT/nodejs/corepack" npm_config_update_notifier=false npm_config_unsafe_perm=true
for _PBK_P in "$_PBK_ROOT/go/sdk/bin" "$_PBK_ROOT/rust/cargo/bin" "$_PBK_ROOT/csharp/dotnet" "$_PBK_ROOT/kotlin/jdk/bin" "$_PBK_ROOT/kotlin/android-sdk/cmdline-tools/latest/bin" "$_PBK_ROOT/kotlin/android-sdk/platform-tools" "$_PBK_ROOT/kotlin/android-sdk/emulator" "$_PBK_ROOT/nodejs/node/bin" "$_PBK_ROOT/python/bin"; do
 if [[ -d "$_PBK_P" ]]; then chmod +x "$_PBK_P"/* 2>/dev/null || true; export PATH="$_PBK_P:$PATH"; fi
done
if [[ -d "$_PBK_ROOT/python/runtimes" ]]; then
 for _PBK_D in "$_PBK_ROOT/python/runtimes"/*/bin; do
  if [[ -d "$_PBK_D" ]]; then chmod +x "$_PBK_D"/* 2>/dev/null || true; export PATH="$_PBK_D:$PATH"; fi
 done
fi
if [[ -d "$_PBK_ROOT/kotlin/android-sdk/ndk" ]]; then
 for _PBK_D in "$_PBK_ROOT/kotlin/android-sdk/ndk"/*; do
  if [[ -d "$_PBK_D" ]]; then export NDK_HOME="$_PBK_D" ANDROID_NDK_HOME="$_PBK_D"; break; fi
 done
fi
unset UV_MANAGED_PYTHON
unset _PBK_P _PBK_D _PBK_ROOT
EOF
}
activate() { write_env; source "$ROOT/env.sh"; }
install_go() {
 [[ -x "$ROOT/go/sdk/bin/go" ]] && { log 'go already present'; return; }
 requires awk
 # ponytail: split locals — bash set -u treats `$name` as unbound in the same `local` line
 local name="go${GO_VERSION}.linux-${go_arch}.tar.gz" meta checksum tmp
 tmp="$ROOT/_state/$name"
 # include=all: 기본 목록은 최신 패치만 담아 고정 버전이 새 패치 출시 즉시 사라짐
 meta="$(curl -fsSL 'https://go.dev/dl/?mode=json&include=all')"
 # here-string: 파이프로 넘기면 awk 조기 exit 시 대용량 JSON의 printf가 SIGPIPE → pipefail로 중단
 checksum="$(awk -F'"' -v n="$name" 'index($0,"\"filename\"") {hit=(index($0,n)>0)} hit && index($0,"\"sha256\"") {print $4;exit}' <<<"$meta")"
 [[ "${#checksum}" -eq 64 ]] || fail "Cannot validate Go checksum for $name (version may be unavailable)"
 fetch "https://go.dev/dl/$name" "$tmp"; sha_check "$tmp" "$checksum"
 mkdir -p "$ROOT/go/sdk"; extract_one "$tmp" "$ROOT/go/sdk"; rm -f "$tmp"
 log 'Installed Go.'
}
install_rust() {
 [[ -x "$ROOT/rust/cargo/bin/cargo" ]] && { log 'rust already present'; return; }
 local uri="https://static.rust-lang.org/rustup/dist/${rust_arch}-unknown-linux-gnu/rustup-init" tmp="$ROOT/_state/rustup-init" expected
 fetch "$uri.sha256" "$tmp.sha256"; expected="$(awk '{print $1}' "$tmp.sha256")"
 [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || fail 'Rustup hash unavailable'
 fetch "$uri" "$tmp"; sha_check "$tmp" "$expected"; chmod +x "$tmp"
 activate; RUSTUP_INIT_SKIP_PATH_CHECK=yes RUSTUP_HOME="$ROOT/rust/rustup" CARGO_HOME="$ROOT/rust/cargo" "$tmp" -y --no-modify-path --profile minimal --default-toolchain stable
 rm -f "$tmp" "$tmp.sha256"
 if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
  log 'WARNING: no system C linker (cc/gcc). rustc installs, but cargo build/prime needs build-essential (or equivalent).'
 fi
}
install_csharp() {
 [[ -x "$ROOT/csharp/dotnet/dotnet" ]] && { log 'dotnet already present'; return; }
 ensure_dir "$ROOT/csharp/dotnet"
 fetch 'https://dot.net/v1/dotnet-install.sh' "$ROOT/_state/dotnet-install.sh"
 bash "$ROOT/_state/dotnet-install.sh" --channel "$DOTNET_CHANNEL" --install-dir "$ROOT/csharp/dotnet" --no-path
}
install_nodejs() {
 [[ -x "$ROOT/nodejs/node/bin/node" ]] && { log 'node already present'; return; }
 local sums="$(curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/SHASUMS256.txt")" filename expected tmp
 filename="$(printf '%s\n' "$sums" | awk -v m="$NODE_MAJOR" -v a="$([[ "$host_arch" == x64 ]] && echo x64 || echo arm64)" '$2 ~ ("^node-v" m "[.]" ) && $2 ~ ("-linux-" a "[.]tar[.]gz$") {print $2;exit}')"
 [[ -n "$filename" ]] || fail "No Node LTS archive for Linux $host_arch"
 expected="$(printf '%s\n' "$sums" | awk -v f="$filename" '$2==f {print $1;exit}')"
 tmp="$ROOT/_state/$filename"; fetch "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/$filename" "$tmp"; sha_check "$tmp" "$expected"
 ensure_dir "$ROOT/nodejs/node"; extract_one "$tmp" "$ROOT/nodejs/node"; rm -f "$tmp"
}
relativize_python_links() {
 local l target rel
 for l in "$ROOT/python/bin"/python*; do
  [[ -L "$l" ]] || continue
  target="$(readlink "$l")"
  if [[ "$target" == "$ROOT/python/runtimes/"* ]]; then
   rel="../runtimes/${target#"$ROOT/python/runtimes/"}"
   ln -snf "$rel" "$l" 2>/dev/null || true
  fi
 done
}
install_python() {
 [[ -x "$ROOT/python/bin/uv" ]] || {
  ensure_dir "$ROOT/python/bin"
  fetch 'https://astral.sh/uv/install.sh' "$ROOT/_state/uv-install.sh"
  UV_UNMANAGED_INSTALL="$ROOT/python/bin" sh "$ROOT/_state/uv-install.sh"
 }
 activate; "$ROOT/python/bin/uv" python install "$PYTHON_VERSION" --default
 relativize_python_links
 activate
 command -v python >/dev/null 2>&1 && python --version || fail "Portable python executable missing from .build/python"
}
install_kotlin() {
 [[ "$host_arch" == x64 ]] || fail 'Android CLI tools Linux archive currently requires x64 host in this script'
 local jdk="$ROOT/kotlin/jdk" sdk="$ROOT/kotlin/android-sdk" tmp api checksum
 if [[ ! -x "$jdk/bin/java" ]]; then
  api="https://api.adoptium.net/v3/assets/latest/${JDK_MAJOR}/hotspot?architecture=x64&image_type=jdk&os=linux&vendor=eclipse"
  checksum="$(curl -fsSL "$api" | grep -oE '"checksum"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]{64}"' | head -n 1 | grep -oE '[0-9a-fA-F]{64}' || true)"
  [[ ${#checksum} -eq 64 ]] || fail 'Cannot obtain verified Temurin JDK checksum'
  tmp="$ROOT/_state/temurin.tar.gz"
  fetch "https://api.adoptium.net/v3/binary/latest/${JDK_MAJOR}/ga/linux/x64/jdk/hotspot/normal/eclipse" "$tmp"
  sha_check "$tmp" "$checksum"; mkdir -p "$jdk"; extract_one "$tmp" "$jdk"; rm -f "$tmp"
 fi
 if [[ ! -x "$sdk/cmdline-tools/latest/bin/sdkmanager" ]]; then
  tmp="$ROOT/_state/android-cli.zip"
  fetch 'https://dl.google.com/android/repository/commandlinetools-linux-15859902_latest.zip' "$tmp"
  sha_check "$tmp" '4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583'
  mkdir -p "$sdk/cmdline-tools/latest"
  extract_one "$tmp" "$sdk/cmdline-tools/latest"; rm -f "$tmp"
  # archive contains cmdline-tools/, so move contents up one level if needed
  if [[ -d "$sdk/cmdline-tools/latest/cmdline-tools" ]]; then
   mv "$sdk/cmdline-tools/latest/cmdline-tools/"* "$sdk/cmdline-tools/latest/"
   rmdir "$sdk/cmdline-tools/latest/cmdline-tools"
  fi
 fi
 activate
 local mgr="$sdk/cmdline-tools/latest/bin/sdkmanager"
 if ((ACCEPT_LICENSES)); then
  local answers="$ROOT/_state/android-licenses.txt"
  for _ in $(seq 1 80); do printf 'y\n'; done > "$answers"
  "$mgr" --sdk_root="$sdk" --licenses < "$answers"; rm -f "$answers"
 else
  log 'Android licenses NOT auto-accepted. If SDK download is blocked, rerun with --accept-android-licenses after reviewing licenses.'
 fi
 local packages=("platforms;android-${ANDROID_API}" "build-tools;${BUILD_TOOLS}")
 ((WITH_ADB)) && packages+=("platform-tools")
 ((WITH_NDK)) && packages+=("ndk;${NDK_VERSION}")
 "$mgr" --sdk_root="$sdk" --install "${packages[@]}"
 log "Android SDK installed: API ${ANDROID_API}, Build Tools ${BUILD_TOOLS}; no emulator/system images."
}
# Optional Android emulator: not included in normal Kotlin installation.
android_image_package() { printf 'system-images;android-%s;%s;%s' "$ANDROID_API" "$EMULATOR_FLAVOR" "$EMULATOR_ABI"; }
android_emulator_ready() {
 [[ -x "$ROOT/kotlin/android-sdk/cmdline-tools/latest/bin/avdmanager" ]] || fail 'Android tools absent: install Kotlin first'
 activate
 ensure_dir "$ANDROID_AVD_HOME"; ensure_dir "$ANDROID_EMULATOR_HOME"
 # 폴더 이동 시 AVD ini 내부의 절대 경로 갱신
 if [[ -f "$ANDROID_AVD_HOME/$AVD_NAME.ini" && -d "$ANDROID_AVD_HOME/$AVD_NAME.avd" ]]; then
  sed -i "s|^path=.*|path=$ANDROID_AVD_HOME/$AVD_NAME.avd|" "$ANDROID_AVD_HOME/$AVD_NAME.ini" 2>/dev/null || true
 fi
}
emulator_install() {
 [[ "$host_arch" == x64 ]] || fail 'This implementation only installs the Android emulator on Linux x86_64'
 # This installs the minimum Android build SDK if it is not already present.
 install_kotlin
 android_emulator_ready
 local sdk="$ROOT/kotlin/android-sdk" package
 package="$(android_image_package)"
 "$sdk/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$sdk" --install emulator platform-tools "$package"
 [[ -x "$sdk/emulator/emulator" ]] || fail 'Android emulator executable missing after SDK installation'
 if [[ -f "$ANDROID_AVD_HOME/$AVD_NAME.ini" ]]; then log "AVD already exists: $AVD_NAME"; return; fi
 # The device defaults to a generic profile; no Play Store or duplicate images by default.
 printf 'no\n' | "$sdk/cmdline-tools/latest/bin/avdmanager" create avd -n "$AVD_NAME" -k "$package" --force
 [[ -f "$ANDROID_AVD_HOME/$AVD_NAME.ini" ]] || fail 'AVD was not created under the portable Android AVD directory'
 log "Installed emulator + single system image ($package); AVD=$AVD_NAME"
}
emulator_list() {
 android_emulator_ready
 "$ROOT/kotlin/android-sdk/cmdline-tools/latest/bin/avdmanager" list avd
 if [[ -x "$ROOT/kotlin/android-sdk/emulator/emulator" ]]; then "$ROOT/kotlin/android-sdk/emulator/emulator" -list-avds; fi
}
emulator_start() {
 android_emulator_ready
 [[ -f "$ANDROID_AVD_HOME/$AVD_NAME.ini" ]] || fail "AVD not installed: $AVD_NAME. Run emulator-install first"
 local exe="$ROOT/kotlin/android-sdk/emulator/emulator" log_file="$ANDROID_EMULATOR_HOME/${AVD_NAME}-emulator.log"
 [[ -x "$exe" ]] || fail 'Emulator package missing'
 local flags=(-avd "$AVD_NAME" -no-snapshot)
 ((EMULATOR_HEADLESS)) && flags+=(-no-window -no-audio)
 nohup "$exe" "${flags[@]}" > "$log_file" 2>&1 < /dev/null &
 log "Emulator launched (pid=$!, log=$log_file). Hardware virtualization and host graphics are required for acceleration."
}
emulator_remove() {
 android_emulator_ready
 local avd="$ROOT/kotlin/android-sdk/cmdline-tools/latest/bin/avdmanager" sdk="$ROOT/kotlin/android-sdk" package
 if [[ -f "$ANDROID_AVD_HOME/$AVD_NAME.ini" ]]; then
  "$avd" delete avd -n "$AVD_NAME"
  log "AVD removed: $AVD_NAME"
 else log "AVD absent: $AVD_NAME"; fi
 if ((PURGE_EMULATOR_PACKAGES)); then
  # Prevent deletion of packages while another portable AVD uses them.
  if find "$ANDROID_AVD_HOME" -maxdepth 1 -name '*.ini' -print -quit | grep -q .; then
   fail 'Other AVDs exist; only selected AVD deleted. Refusing to uninstall shared system image/emulator.'
  fi
  package="$(android_image_package)"
  "$sdk/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$sdk" --uninstall "$package" emulator
  log 'Emulator package and selected system image removed (ADB retained for other workflows).'
 fi
}
# Project-specific deterministic cache root; dependencies NEVER installed globally.
project_ref() {
 local base="$(dirname "$ROOT")"
 if [[ "$PROJECT" == "$base" ]]; then printf '.'
 elif [[ "$PROJECT" == "$base/"* ]]; then printf '%s' "${PROJECT#"$base/"}"
 else printf '%s' "$PROJECT"; fi
}
project_key() { project_ref | sha256sum | cut -c1-12; }
project_rust_target() { printf '%s/rust/targets/%s' "$ROOT" "$(project_key)"; }
project_gradle_cache() { printf '%s/kotlin/project-caches/%s' "$ROOT" "$(project_key)"; }
node_store() { printf '%s/nodejs/projects/%s' "$ROOT" "$(project_key)"; }
node_link_path() { printf '%s/node_modules' "$PROJECT"; }
node_lock_hash() { sha256sum "$PROJECT/package-lock.json" | awk '{print $1}'; }
# 일반 폴더를 보호하고 이동된 관리 복사본의 마커만 현재 경로로 갱신합니다.
node_check_link() {
 local store="$1" link target
 link="$(node_link_path)"; target="$store/node_modules"
 if [[ -L "$link" ]]; then
   local actual; actual="$(readlink -f "$link")"
   [[ "$actual" == "$target" ]] || fail "Project has an unmanaged node_modules link: $link"
 elif [[ -f "$link/.pbk-managed" ]]; then
   local previous; previous="$(cat "$link/.pbk-managed")"
   if [[ "$previous" != "$target" ]]; then
    [[ "$previous" == /*/nodejs/projects/"${store##*/}"/node_modules && -f "$store/project.txt" && -d "$target" ]] || fail "Project has an unmanaged node_modules copy: $link"
    [[ "$(cat "$store/project.txt")" == "$(project_ref)" ]] || fail "Node project identity mismatch: $store"
    printf '%s\n' "$target" > "$link/.pbk-managed"
   fi
 elif [[ -e "$link" ]]; then
   fail "Existing unmanaged node_modules detected: $link. Back it up manually before portable prime."
 fi
}
node_link_or_copy() {
 local target="$1" link="$2"
 if ln -s "$(realpath --relative-to="$PROJECT" "$target")" "$link" 2>/dev/null; then return 0; fi
 # 심볼릭 링크 미지원 파일시스템(exFAT 등) 폴백: 복사본 + 관리 마커 기록
 cp -RP --preserve=mode,links "$target" "$link" 2>/dev/null || cp -R "$target" "$link"
 printf '%s\n' "$target" > "$link/.pbk-managed"
}
node_prime() {
 [[ -f "$PROJECT/package-lock.json" ]] || fail 'package-lock.json missing. Create and commit lockfile online first.'
 [[ -f "$PROJECT/package.json" ]] || fail 'package.json missing'
 local store="$(node_store)" link="$(node_link_path)" digest="$(node_lock_hash)"
 ensure_dir "$store"
 if [[ -f "$store/project.txt" ]]; then
  [[ "$(cat "$store/project.txt")" == "$(project_ref)" ]] || fail "Node project hash collision: $store"
 fi
 node_check_link "$store"
 if [[ -L "$link" ]]; then rm -- "$link"; elif [[ -f "$link/.pbk-managed" ]]; then rm_tree "$link"; fi
 if [[ -d "$store/node_modules" ]]; then rm_tree "$store/node_modules"; fi
 (cd "$PROJECT" && npm ci --include=optional)
 [[ -d "$link" ]] || fail 'npm ci completed without node_modules'
 mv -- "$link" "$store/node_modules"
 printf '%s\n' "$(project_ref)" > "$store/project.txt"
 printf '%s\n' "$digest" > "$store/package-lock.sha256"
 node_link_or_copy "$store/node_modules" "$link"
 log "Node dependencies stored under $store; project node_modules is only a symlink."
}
node_offline_prepare() {
 [[ -f "$PROJECT/package-lock.json" ]] || fail 'package-lock.json missing'
 local store="$(node_store)" link="$(node_link_path)"
 [[ -f "$store/package-lock.sha256" ]] || fail 'No dependency snapshot. Run nodejs prime while online.'
 [[ "$(cat "$store/package-lock.sha256")" == "$(node_lock_hash)" ]] || fail 'package-lock changed; online prime required.'
 [[ -d "$store/node_modules" ]] || fail 'Portable node_modules is missing.'
 node_check_link "$store"
 [[ -L "$link" || -f "$link/.pbk-managed" ]] || node_link_or_copy "$store/node_modules" "$link"
}
cleanup_node_links() {
 # 정리할 프로젝트를 기준으로 이전 경로의 관리 마커도 검증합니다.
 local store proj link target
 for store in "$ROOT/nodejs/projects"/*; do
  [[ -f "$store/project.txt" ]] || continue
  proj="$(cat "$store/project.txt")"
  [[ "$proj" == /* ]] || proj="$(dirname "$ROOT")/$proj"
  link="$proj/node_modules"; target="$store/node_modules"
  if [[ -L "$link" && "$(readlink -f "$link")" == "$target" ]]; then rm -- "$link"
  elif [[ -f "$link/.pbk-managed" ]]; then PROJECT="$proj" node_check_link "$store"; rm_tree "$link"; fi
 done
}
install_tauri() {
 install_rust; install_nodejs
 if ((WITH_NDK)); then
  install_kotlin; activate; rustup target add aarch64-linux-android
 fi
 mkdir -p "$ROOT/rust/tauri"
 printf 'Tauri 2 is optional: Rust and Node.js are shared, project dependencies live in .build/nodejs/projects.\n' > "$ROOT/rust/tauri/README.txt"
 if ! command -v pkg-config >/dev/null || ! pkg-config --exists webkit2gtk-4.1 2>/dev/null; then
  log 'WARNING: Tauri Linux host dependencies missing (WebKitGTK 4.1 etc.). See official Tauri prerequisites.'
 fi
}
verify_tauri() {
 verify_one rust; verify_one nodejs
 command -v pkg-config >/dev/null || fail 'Tauri requires host pkg-config'
 pkg-config --exists webkit2gtk-4.1 || fail 'Tauri requires host WebKitGTK 4.1 development libraries'
 pkg-config --exists openssl || fail 'Tauri requires host OpenSSL development libraries'
 requires cc
 log 'Host prerequisites partially checked; real bundling/targets still require project build tests.'
}
prime_tauri() {
 [[ -f "$PROJECT/src-tauri/Cargo.toml" ]] || fail 'src-tauri/Cargo.toml missing'
 if [[ "${1:-online}" == offline ]]; then
  node_offline_prepare
  (cd "$PROJECT" && npm_config_offline=true npm run build --if-present)
  (cd "$PROJECT/src-tauri" && CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$(project_rust_target)" cargo build --offline)
 else
  node_prime
  (cd "$PROJECT" && npm run build --if-present)
  (cd "$PROJECT/src-tauri" && CARGO_TARGET_DIR="$(project_rust_target)" cargo fetch && CARGO_TARGET_DIR="$(project_rust_target)" cargo build)
 fi
}
vue_init() {
 install_nodejs; activate
 [[ -z "$(find "$PROJECT" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail "Vue scaffold target must be empty: $PROJECT"
 # Official create-vue --typescript flag suppresses interactive feature prompts.
 (cd "$PROJECT" && npm create vue@latest -- --typescript .)
 log 'Vue scaffold complete. Run nodejs prime --project <path> to capture dependencies.'
}
install_one() {
 case "$1" in go) install_go;; rust) install_rust;; csharp) install_csharp;; nodejs) install_nodejs;; python) install_python;; kotlin) install_kotlin;; esac
}
langs() { if [[ "$LANG_NAME" == all ]]; then echo 'go rust kotlin csharp python'; else echo "$LANG_NAME"; fi; }
verify_one() {
 case "$1" in
  go) command -v go >/dev/null && go version;; rust) command -v rustc >/dev/null && rustc --version;;
  kotlin) [[ -x "$ROOT/kotlin/jdk/bin/java" && -x "$ROOT/kotlin/android-sdk/cmdline-tools/latest/bin/sdkmanager" ]] && java -version && sdkmanager --sdk_root="$ANDROID_HOME" --list_installed || return 1;;
  csharp) command -v dotnet >/dev/null && dotnet --version;;
  nodejs) [[ -x "$ROOT/nodejs/node/bin/node" ]] && "$ROOT/nodejs/node/bin/node" --version && "$ROOT/nodejs/node/bin/npm" --version;;
  python) [[ -x "$ROOT/python/bin/uv" ]] && uv python list --only-installed || return 1;;
 esac
}
prime_one() {
 cd "$PROJECT"
 case "$1" in
  go) [[ -f go.mod ]] || fail 'go.mod missing'; go mod download; go test ./...;;
  rust) [[ -f Cargo.toml ]] || fail 'Cargo.toml missing'; CARGO_TARGET_DIR="$(project_rust_target)" cargo fetch; CARGO_TARGET_DIR="$(project_rust_target)" cargo build;;
  kotlin) [[ -f gradlew ]] || fail 'gradlew missing'; bash ./gradlew "$TASK" --no-daemon --project-cache-dir "$(project_gradle_cache)";;
  csharp) dotnet restore; dotnet build --no-restore;;
  nodejs) node_prime; (cd "$PROJECT" && npm run build --if-present);;
  python)
   local py_env="$ROOT/python/envs/$(project_key)"
   export UV_PROJECT_ENVIRONMENT="$py_env"
   if [[ -f uv.lock ]]; then uv sync --locked
   elif [[ -f pyproject.toml ]]; then uv sync
   elif [[ -f requirements.txt ]]; then uv venv --python "$PYTHON_VERSION" --allow-existing "$py_env"; uv pip install --python "$py_env/bin/python" -r requirements.txt
   else fail 'Requires uv.lock, pyproject.toml or requirements.txt'; fi;;
 esac
}
offline_one() {
 cd "$PROJECT"
 case "$1" in
  go) GOPROXY=off GOSUMDB=off go test ./...;;
  rust) CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$(project_rust_target)" cargo build --offline;;
  kotlin) bash ./gradlew "$TASK" --offline --no-daemon --project-cache-dir "$(project_gradle_cache)";;
  csharp) dotnet build --no-restore;;
  nodejs) node_offline_prepare; npm_config_offline=true npm run build --if-present;;
  python)
   local py_env="$ROOT/python/envs/$(project_key)"
   export UV_PROJECT_ENVIRONMENT="$py_env"
   if [[ -f uv.lock ]]; then uv sync --offline --locked; elif [[ -f requirements.txt ]]; then uv pip install --offline --python "$py_env/bin/python" -r requirements.txt; else uv sync --offline; fi;;
 esac
}
global_on() {
 local rc="$HOME/.bashrc" mark='# >>> portable-build-kit managed >>>'
 [[ ! -f "$ROOT/_state/global-bash-enabled" ]] || { log 'Already registered in ~/.bashrc'; return; }
 if [[ -e "$rc" ]] && grep -Fq "$mark" "$rc"; then fail 'Managed block exists in ~/.bashrc but no state marker; refusing duplicate'; fi
 [[ -e "$rc" ]] || : > "$rc"
 printf '\n%s\nsource %q\n%s\n' "$mark" "$ROOT/env.sh" '# <<< portable-build-kit managed <<<' >> "$rc"
 printf '%s\n' "$rc" > "$ROOT/_state/global-bash-enabled"
 log "Registered in $rc. Reopen shell or source .build/env.sh"
}
global_off() {
 local marker="$ROOT/_state/global-bash-enabled" rc
 [[ -f "$marker" ]] || { log 'No managed Bash shell profile registration'; return; }
 rc="$(cat "$marker")"; [[ -f "$rc" ]] || { rm -f "$marker"; return; }
 local tmp="$ROOT/_state/bashrc.$$"
 awk '/^# >>> portable-build-kit managed >>>$/ {skip=1;next} /^# <<< portable-build-kit managed <<<$/ {skip=0;next} !skip {print}' "$rc" > "$tmp"
 cat "$tmp" > "$rc"; rm -f "$tmp" "$marker"
 log 'Removed managed shell profile block; other content preserved.'
}
# Facade UI: precisely four primary actions, all details delegated to submenus.
ask_language() {
 if [[ "$LANG_NAME" == all ]]; then
  local v
  read -r -p 'Language (go/rust/kotlin/csharp/nodejs/python/all) [all]: ' v
  LANG_NAME="${v:-all}"
  case "$LANG_NAME" in all|go|rust|kotlin|csharp|nodejs|python) ;; *) fail 'Invalid language';; esac
 fi
}
ask_licenses() {
 if [[ "$LANG_NAME" == kotlin || "$LANG_NAME" == all ]]; then
  local yn; read -r -p 'If you have reviewed Android SDK licenses, accept? (yes/no): ' yn
  [[ "$yn" == yes ]] && ACCEPT_LICENSES=1
 fi
}
extra_menu() {
 local choice label="${LANG_NAME}"
 case "$LANG_NAME" in
  kotlin)
   echo 'Android emulator: 1 install | 2 list | 3 start | 4 remove | 0 back'
   read -r -p 'Choice: ' choice
   case "$choice" in 1) OPERATION=install;;2) OPERATION=list;;3) OPERATION=start;;4) OPERATION=remove;;0) return 1;;*) fail 'Invalid emulator choice';; esac
   FEATURE=emulator
   if [[ "$OPERATION" == install ]]; then
    read -r -p "Android API [$ANDROID_API]: " label; ANDROID_API="${label:-$ANDROID_API}"
    read -r -p "AVD name [$AVD_NAME]: " label; AVD_NAME="${label:-$AVD_NAME}"
    read -r -p 'Reviewed/accept Android SDK licenses? (yes/no): ' label
    [[ "$label" == yes ]] && ACCEPT_LICENSES=1
   elif [[ "$OPERATION" == start || "$OPERATION" == remove ]]; then
    read -r -p "AVD name [$AVD_NAME]: " label; AVD_NAME="${label:-$AVD_NAME}"
   fi
   if [[ "$OPERATION" == start ]]; then
    read -r -p 'Headless? (yes/no): ' label; [[ "$label" == yes ]] && EMULATOR_HEADLESS=1
   elif [[ "$OPERATION" == remove ]]; then
    read -r -p 'Also remove unused emulator packages? (yes/no): ' label; [[ "$label" == yes ]] && PURGE_EMULATOR_PACKAGES=1
   fi;;
  rust)
   echo 'Tauri 2: 1 install | 2 verify | 3 prime | 4 offline-check | 5 remove | 0 back'
   read -r -p 'Choice: ' choice
   case "$choice" in 1) OPERATION=install;;2) OPERATION=verify;;3) OPERATION=prime;;4) OPERATION=offline-check;;5) OPERATION=remove;;0) return 1;;*) fail 'Invalid Tauri choice';; esac
   FEATURE=tauri;;
  nodejs)
   echo 'Vue project: 1 initialize (empty target folder) | 0 back'
   read -r -p 'Choice: ' choice
   case "$choice" in 1) FEATURE=vue; OPERATION=init;;0) return 1;;*) fail 'Invalid Vue choice';; esac;;
  *) echo 'No optional features for this language.'; return 1;;
 esac
}
menu() {
 local n sub confirm
 echo "=== Portable Build Kit: ${LANG_NAME} ==="
 echo '1. 설치 (Install)'
 echo '2. 환경설정 (Configure)'
 echo '3. 최신화 (Update)'
 echo '4. 초기화 (Reset)'
 echo '0. 종료'
 read -r -p 'Choose: ' n
 case "$n" in
  1) ACTION=install; ask_language; ask_licenses;;
  2)
   ACTION=configure; ask_language
   echo 'Configuration: 1 verify | 2 session env | 3 global-on | 4 global-off'
   echo '               5 prime dependencies | 6 offline-check | 7 list | 8 optional features | 0 back'
   read -r -p 'Choice: ' sub
   case "$sub" in 1) MODE=verify;;2) MODE=env;;3) MODE=global-on;;4) MODE=global-off;;5) MODE=prime;;6) MODE=offline-check;;7) MODE=list;;8) extra_menu || exit 0;;0) exit 0;;*) fail 'Invalid config choice';; esac;;
  3) ACTION=update; ask_language; ask_licenses;;
  4)
   ACTION=reset; ask_language
   echo 'Reset: 1 restore environment + delete managed tools | 2 restore environment only | 3 delete tools only | 0 back'
   read -r -p 'Choice: ' sub
   case "$sub" in 1) SCOPE=all;;2) SCOPE=env;;3) SCOPE=tools;;0) exit 0;;*) fail 'Invalid reset choice';; esac
   read -r -p "Confirm reset [$LANG_NAME/$SCOPE] (type RESET): " confirm
   [[ "$confirm" == RESET ]] || { log 'Cancelled'; exit 0; }
   CONFIRM_RESET=1;;
  0) exit 0;;
  *) fail 'Invalid menu choice';;
 esac
}
if [[ "$ACTION" == menu ]]; then menu; fi
# Validate values again after interactive selection to avoid unsafe AVD paths/names.
[[ "$ANDROID_API" =~ ^[0-9]+$ ]] || fail 'Android API must be numeric'
[[ "$AVD_NAME" =~ ^[A-Za-z][A-Za-z0-9_.-]{0,63}$ ]] || fail 'Invalid AVD name'
[[ "$EMULATOR_ABI" == x86_64 || "$EMULATOR_ABI" == arm64-v8a ]] || fail 'Invalid emulator ABI'
[[ "$EMULATOR_FLAVOR" == default || "$EMULATOR_FLAVOR" == google_apis ]] || fail 'Invalid emulator image flavor'
write_env
# Public Facade operations: command/UI adapters never call installer internals directly.
facade_install() {
 local l
 for l in $(langs); do log "Installing $l"; install_one "$l"; done
 write_env
}
facade_configure() {
 local op="$MODE"
 case "$FEATURE" in
  none) ;;
  emulator)
   [[ "$LANG_NAME" == kotlin ]] || fail 'Emulator feature requires kotlin'
   case "$OPERATION" in install) emulator_install;;list) emulator_list;;start) emulator_start;;remove) emulator_remove;;*) fail 'Invalid emulator operation';; esac
   return;;
  tauri)
   [[ "$LANG_NAME" == rust ]] || fail 'Tauri feature requires rust'
   case "$OPERATION" in
    install) install_tauri;; verify) activate; verify_tauri;;
    prime) activate; prime_tauri online;;offline-check) activate; prime_tauri offline;;
    remove) rm -rf -- "$ROOT/rust/tauri"; log 'Removed Tauri marker; shared compiler retained';;
    *) fail 'Invalid Tauri operation';;
   esac
   return;;
  vue)
   [[ "$LANG_NAME" == nodejs && "$OPERATION" == init ]] || fail 'Vue requires nodejs and init'
   vue_init; return;;
  *) fail 'Unknown optional feature';;
 esac
 case "$op" in
  verify) activate; local bad=0 l; for l in $(langs); do verify_one "$l" || { log "FAILED: $l"; bad=1; }; done; return "$bad";;
  env) printf 'Run: source %q\n' "$ROOT/env.sh";;
  global-on) global_on;;global-off) global_off;;
  prime) activate; [[ "$LANG_NAME" != all ]] || fail 'prime requires a single language'; prime_one "$LANG_NAME";;
  offline-check) activate; [[ "$LANG_NAME" != all ]] || fail 'offline-check requires a single language'; offline_one "$LANG_NAME";;
  list) local l; for l in go rust kotlin csharp nodejs python; do if [[ -d "$ROOT/$l" ]]; then printf '%-8s installed\n' "$l"; else printf '%-8s absent\n' "$l"; fi; done;;
  run) activate; ((${#RUN_ARGS[@]})) || fail 'run requires -- command'; "${RUN_ARGS[@]}";;
  *) fail "Invalid configure mode: $op";;
 esac
}
latest_go_version() {
 # go.dev releases JSON is sorted newest stable to oldest.
 local version
 version="$(curl -fsSL 'https://go.dev/dl/?mode=json' | grep -m1 -oE '"version"[[:space:]]*:[[:space:]]*"go[0-9]+\.[0-9]+(\.[0-9]+)?"' | grep -oE 'go[0-9]+\.[0-9]+(\.[0-9]+)?' || true)"
 [[ -n "$version" ]] || fail 'Unable to resolve latest stable Go version'
 printf '%s' "${version#go}"
}
facade_update_one() {
 local l="$1" old="$ROOT/_state/update-backup-${l}"
 case "$l" in
  go)
   [[ -x "$ROOT/go/sdk/bin/go" ]] || fail 'Go missing. Run install first.'
   ((GO_VERSION_EXPLICIT)) || GO_VERSION="$(latest_go_version)"
   if [[ "$("$ROOT/go/sdk/bin/go" version)" == *"go${GO_VERSION} "* ]]; then log "Go already at $GO_VERSION"; return; fi
   [[ ! -e "$old" ]] || fail "Incomplete previous update exists: $old"
   mv "$ROOT/go/sdk" "$old"
   if (install_go); then rm_tree "$old"; else
    rm_tree "$ROOT/go/sdk"; mv "$old" "$ROOT/go/sdk"; fail 'Go upgrade failed; previous toolchain restored'
   fi;;
  rust)
   [[ -x "$ROOT/rust/cargo/bin/rustup" ]] || fail 'Rust missing. Run install first.'
   activate; rustup set profile minimal; rustup update stable;;
  csharp)
   [[ -x "$ROOT/csharp/dotnet/dotnet" ]] || fail '.NET missing. Run install first.'
   fetch 'https://dot.net/v1/dotnet-install.sh' "$ROOT/_state/dotnet-install.sh"
   bash "$ROOT/_state/dotnet-install.sh" --channel "$DOTNET_CHANNEL" --install-dir "$ROOT/csharp/dotnet" --no-path;;
  nodejs)
   [[ -x "$ROOT/nodejs/node/bin/node" ]] || fail 'Node.js missing. Run install first.'
   local latest latest_version
   latest="$(curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/SHASUMS256.txt" | grep -oE 'node-v[0-9]+\.[0-9]+\.[0-9]+-linux-' | head -n 1 || true)"
   latest_version="${latest#node-}"; latest_version="${latest_version%-linux-}"
   [[ "$latest_version" == v* ]] || fail 'Cannot resolve latest Node.js version'
   if [[ "$("$ROOT/nodejs/node/bin/node" --version)" == "$latest_version" ]]; then log "Node.js already at $latest_version"; return; fi
   [[ ! -e "$old" ]] || fail "Incomplete previous update exists: $old"
   mv "$ROOT/nodejs/node" "$old"
   if (install_nodejs); then rm_tree "$old"; else
    rm_tree "$ROOT/nodejs/node"; mv "$old" "$ROOT/nodejs/node"; fail 'Node.js upgrade failed; previous toolchain restored'
   fi;;
  python)
   [[ -x "$ROOT/python/bin/uv" ]] || fail 'Python/uv missing. Run install first.'
   # uv unmanaged mode disallows 'uv self update'; refresh the local installer in place.
   fetch 'https://astral.sh/uv/install.sh' "$ROOT/_state/uv-install.sh"
   UV_UNMANAGED_INSTALL="$ROOT/python/bin" sh "$ROOT/_state/uv-install.sh"
   activate; uv python install "$PYTHON_VERSION" --default
   relativize_python_links
   log 'Python updated within requested version line. Review existing venv pins.';;
  kotlin)
   [[ -x "$ROOT/kotlin/android-sdk/cmdline-tools/latest/bin/sdkmanager" ]] || fail 'Android SDK missing. Run install first.'
   # Do not issue sdkmanager --update: that could add unwanted platforms / package versions.
   install_kotlin
   log 'Ensured exact requested API/build-tools/NDK selection. JDK & CLI tool upgrades require separate tested version pins.';;
 esac
}
facade_update() {
 # Keep project lockfiles, offline caches and unrelated toolchains untouched.
 local l
 for l in $(langs); do log "Updating $l"; facade_update_one "$l"; done
}
facade_reset() {
 if [[ "$SCOPE" != env && "$CONFIRM_RESET" != 1 ]]; then fail "Reset deletes toolchains; pass --yes after reviewing scope."; fi
 case "$SCOPE" in
  all) global_off;;
  env) global_off; return;;
  tools) [[ ! -f "$ROOT/_state/global-bash-enabled" ]] || fail 'Restore globals first or use --scope all';;
  *) fail 'Invalid reset scope';;
 esac
 if [[ "$LANG_NAME" == all || "$LANG_NAME" == nodejs ]]; then cleanup_node_links; fi
 local l
 if [[ "$LANG_NAME" == all ]]; then
  for l in go rust kotlin csharp python nodejs; do rm_tree "$ROOT/$l"; log "Removed $l"; done
 else
  rm_tree "$ROOT/$LANG_NAME"; log "Removed $LANG_NAME"
 fi
}
case "$ACTION" in
 install) facade_install;;
 configure) facade_configure;;
 update) facade_update;;
 reset) facade_reset;;
 vue-init) [[ "$LANG_NAME" == nodejs ]] || fail "vue-init belongs to nodejs"; vue_init;;
 tauri-install) [[ "$LANG_NAME" == rust ]] || fail "Tauri actions belong to rust"; install_tauri;;
 tauri-verify) [[ "$LANG_NAME" == rust ]] || fail "Tauri actions belong to rust"; activate; verify_tauri;;
 tauri-prime) [[ "$LANG_NAME" == rust ]] || fail "Tauri actions belong to rust"; activate; prime_tauri online;;
 tauri-offline-check) [[ "$LANG_NAME" == rust ]] || fail "Tauri actions belong to rust"; activate; prime_tauri offline;;
 tauri-remove) [[ "$LANG_NAME" == rust ]] || fail "Tauri actions belong to rust"; rm_tree "$ROOT/rust/tauri"; log "Removed optional Tauri marker; shared tools/caches preserved";;
 emulator-install) emulator_install;;
 emulator-list) emulator_list;;
 emulator-start) emulator_start;;
 emulator-remove) emulator_remove;;
 verify) activate; bad=0; for l in $(langs); do log "Verify $l"; verify_one "$l" || { log "FAILED: $l"; bad=1; }; done; exit "$bad";;
 prime) activate; [[ "$LANG_NAME" != all ]] || fail 'prime requires --language (one project type at a time)'; prime_one "$LANG_NAME";;
 offline-check) activate; [[ "$LANG_NAME" != all ]] || fail 'offline-check requires --language'; offline_one "$LANG_NAME";;
 env) printf 'Run in current shell: source %q\n' "$ROOT/env.sh";;
 global-on) global_on;;
 global-off) global_off;;
 remove)
  [[ ! -f "$ROOT/_state/global-bash-enabled" ]] || fail 'global-on is active. Run global-off first.'
  if [[ "$LANG_NAME" == all || "$LANG_NAME" == nodejs ]]; then cleanup_node_links; fi
  if [[ "$LANG_NAME" == all ]]; then for l in go rust kotlin csharp python nodejs; do rm_tree "$ROOT/$l"; log "Removed $l"; done
  else rm_tree "$ROOT/$LANG_NAME"; log "Removed $LANG_NAME"; fi;;
 list) for l in go rust kotlin csharp nodejs python; do if [[ -d "$ROOT/$l" ]]; then printf '%-8s installed\n' "$l"; else printf '%-8s absent\n' "$l"; fi; done;;
 run) activate; ((${#RUN_ARGS[@]})) || fail 'run requires -- command [args]'; "${RUN_ARGS[@]}";;
 *) usage; exit 2;;
esac
