#!/usr/bin/env bash
# Kotlin / Android (JDK + Android SDK) - 독립 실행 스크립트 (Linux, Facade 4-액션 내장).
# 이 파일 하나만 복사해도 설치·환경설정(검증/세션/전역/prime/offline-check/emulator)·최신화·초기화가 모두 동작한다.
#   대화형 메뉴: bash kotlin.sh
#   비대화형:    bash kotlin.sh install | configure --mode verify|env|global-on|global-off|prime|offline-check|list|run | update | reset --yes
#   세션 적용:   source kotlin.sh
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LANG_NAME=kotlin
STATE="$ROOT/$LANG_NAME/_state"
pbk_path() { local p; for p in "$@"; do if [[ -d "$p" ]]; then chmod +x "$p"/* 2>/dev/null || true; PATH="$p:$PATH"; fi; done; export PATH; }
activate() {
 export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
 export JAVA_HOME="$ROOT/kotlin/jdk" ANDROID_HOME="$ROOT/kotlin/android-sdk" ANDROID_SDK_ROOT="$ROOT/kotlin/android-sdk" GRADLE_USER_HOME="$ROOT/kotlin/gradle" ANDROID_USER_HOME="$ROOT/kotlin/android-user" ANDROID_PREFS_ROOT="$ROOT/kotlin/android-user" ANDROID_EMULATOR_HOME="$ROOT/kotlin/android-user" ANDROID_AVD_HOME="$ROOT/kotlin/android-user/avd"
 pbk_path "$ROOT/kotlin/jdk/bin" "$ROOT/kotlin/android-sdk/cmdline-tools/latest/bin" "$ROOT/kotlin/android-sdk/platform-tools" "$ROOT/kotlin/android-sdk/emulator"
 local d
 if [[ -d "$ROOT/kotlin/android-sdk/ndk" ]]; then
  for d in "$ROOT/kotlin/android-sdk/ndk"/*; do
   if [[ -d "$d" ]]; then export NDK_HOME="$d" ANDROID_NDK_HOME="$d"; break; fi
  done
 fi
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
case "$(uname -s)" in Linux) ;; *) fail 'This .sh supports Linux. For Windows use kotlin.ps1.';; esac
case "$(uname -m)" in x86_64|amd64) host_arch=x64;; aarch64|arm64) host_arch=aarch64;; *) fail "Unsupported CPU $(uname -m)";; esac
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
ANDROID_API=36 BUILD_TOOLS=36.0.0 JDK_MAJOR=21 NDK_VERSION=27.2.12479018 WITH_NDK=0 WITH_ADB=0 ACCEPT_LICENSES=0
TASK=assembleDebug EMULATOR_ABI=x86_64 EMULATOR_FLAVOR=google_apis AVD_NAME=pbk_android EMULATOR_HEADLESS=0 PURGE_EMULATOR_PACKAGES=0 RUN_ARGS=()
while (($#)); do
 case "$1" in
  menu|install|configure|update|reset|verify|prime|offline-check|env|global-on|global-off|remove|list|run|emulator-install|emulator-list|emulator-start|emulator-remove) ACTION="$1"; shift;;
  --mode) MODE="${2:?}"; shift 2;;
  --feature) FEATURE="${2:?}"; shift 2;;
  --operation) OPERATION="${2:?}"; shift 2;;
  --scope) SCOPE="${2:?}"; shift 2;;
  --yes) YES=1; shift;;
  --project) PROJECT="${2:?}"; shift 2;;
  --task) TASK="${2:?}"; shift 2;;
  --android-api) ANDROID_API="${2:?}"; shift 2;;
  --build-tools) BUILD_TOOLS="${2:?}"; shift 2;;
  --ndk-version) NDK_VERSION="${2:?}"; shift 2;;
  --with-ndk) WITH_NDK=1; shift;;
  --with-adb) WITH_ADB=1; shift;;
  --jdk-major) JDK_MAJOR="${2:?}"; shift 2;;
  --accept-android-licenses) ACCEPT_LICENSES=1; shift;;
  --emulator-abi) EMULATOR_ABI="${2:?}"; shift 2;;
  --emulator-flavor) EMULATOR_FLAVOR="${2:?}"; shift 2;;
  --avd-name) AVD_NAME="${2:?}"; shift 2;;
  --headless) EMULATOR_HEADLESS=1; shift;;
  --purge-emulator-packages) PURGE_EMULATOR_PACKAGES=1; shift;;
  --) shift; RUN_ARGS=("$@"); break;;
  -h|--help) echo "Usage: bash $LANG_NAME.sh [menu|install|configure|update|reset|emulator-*] [options]"; exit 0;;
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
project_gradle_cache() { printf '%s/kotlin/project-caches/%s' "$ROOT" "$(project_key)"; }

install_kotlin() {
 [[ "$host_arch" == x64 ]] || fail 'Android CLI tools Linux archive currently requires x64 host in this script'
 local jdk="$ROOT/kotlin/jdk" sdk="$ROOT/kotlin/android-sdk" tmp api checksum
 if [[ ! -x "$jdk/bin/java" ]]; then
  api="https://api.adoptium.net/v3/assets/latest/${JDK_MAJOR}/hotspot?architecture=x64&image_type=jdk&os=linux&vendor=eclipse"
  checksum="$(curl -fsSL "$api" | grep -oE '"checksum"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]{64}"' | head -n 1 | grep -oE '[0-9a-fA-F]{64}' || true)"
  [[ ${#checksum} -eq 64 ]] || fail 'Cannot obtain verified Temurin JDK checksum'
  tmp="$STATE/temurin.tar.gz"
  fetch "https://api.adoptium.net/v3/binary/latest/${JDK_MAJOR}/ga/linux/x64/jdk/hotspot/normal/eclipse" "$tmp"
  sha_check "$tmp" "$checksum"; ensure_dir "$jdk"; extract_one "$tmp" "$jdk"; rm -f "$tmp"
 fi
 if [[ ! -x "$sdk/cmdline-tools/latest/bin/sdkmanager" ]]; then
  tmp="$STATE/android-cli.zip"
  fetch 'https://dl.google.com/android/repository/commandlinetools-linux-15859902_latest.zip' "$tmp"
  sha_check "$tmp" '4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583'
  ensure_dir "$sdk/cmdline-tools/latest"
  extract_one "$tmp" "$sdk/cmdline-tools/latest"; rm -f "$tmp"
  if [[ -d "$sdk/cmdline-tools/latest/cmdline-tools" ]]; then
   mv "$sdk/cmdline-tools/latest/cmdline-tools/"* "$sdk/cmdline-tools/latest/"
   rmdir "$sdk/cmdline-tools/latest/cmdline-tools"
  fi
 fi
 activate
 local mgr="$sdk/cmdline-tools/latest/bin/sdkmanager"
 if ((ACCEPT_LICENSES)); then
  local answers="$STATE/android-licenses.txt"
  ensure_dir "$STATE"
  for _ in $(seq 1 80); do printf 'y\n'; done > "$answers"
  "$mgr" --sdk_root="$sdk" --licenses < "$answers"; rm -f "$answers"
 else
  log 'Android licenses NOT auto-accepted. If SDK download is blocked, rerun with --accept-android-licenses after reviewing licenses.'
 fi
 local packages=("platforms;android-${ANDROID_API}" "build-tools;${BUILD_TOOLS}")
 if ((WITH_ADB)); then packages+=("platform-tools"); fi
 if ((WITH_NDK)); then packages+=("ndk;${NDK_VERSION}"); fi
 "$mgr" --sdk_root="$sdk" --install "${packages[@]}"
 log "Android SDK installed: API ${ANDROID_API}, Build Tools ${BUILD_TOOLS}; no emulator/system images."
}
do_verify() { [[ -x "$ROOT/kotlin/jdk/bin/java" && -x "$ROOT/kotlin/android-sdk/cmdline-tools/latest/bin/sdkmanager" ]] && java -version && sdkmanager --sdk_root="$ANDROID_HOME" --list_installed || fail 'Kotlin/Android verification failed'; }
do_update() {
 [[ -x "$ROOT/kotlin/android-sdk/cmdline-tools/latest/bin/sdkmanager" ]] || fail 'Android SDK missing. Run install first.'
 install_kotlin
 log 'Ensured exact requested API/build-tools/NDK selection. JDK & CLI tool upgrades require separate tested version pins.'
}
do_prime() {
 [[ -f "$PROJECT/gradlew" ]] || fail 'gradlew missing'
 (cd "$PROJECT" && bash ./gradlew "$TASK" --no-daemon --project-cache-dir "$(project_gradle_cache)")
}
do_offline() {
 [[ -f "$PROJECT/gradlew" ]] || fail 'gradlew missing'
 (cd "$PROJECT" && bash ./gradlew "$TASK" --offline --no-daemon --project-cache-dir "$(project_gradle_cache)")
}
android_image_package() { printf 'system-images;android-%s;%s;%s' "$ANDROID_API" "$EMULATOR_FLAVOR" "$EMULATOR_ABI"; }
android_emulator_ready() {
 [[ -x "$ROOT/kotlin/android-sdk/cmdline-tools/latest/bin/avdmanager" ]] || fail 'Android tools absent: install Kotlin first'
 activate
 ensure_dir "$ANDROID_AVD_HOME"; ensure_dir "$ANDROID_EMULATOR_HOME"
 if [[ -f "$ANDROID_AVD_HOME/$AVD_NAME.ini" && -d "$ANDROID_AVD_HOME/$AVD_NAME.avd" ]]; then
  sed -i "s|^path=.*|path=$ANDROID_AVD_HOME/$AVD_NAME.avd|" "$ANDROID_AVD_HOME/$AVD_NAME.ini" 2>/dev/null || true
 fi
}
emulator_install() {
 [[ "$host_arch" == x64 ]] || fail 'This implementation only installs the Android emulator on Linux x86_64'
 install_kotlin
 android_emulator_ready
 local sdk="$ROOT/kotlin/android-sdk" package
 package="$(android_image_package)"
 "$sdk/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$sdk" --install emulator platform-tools "$package"
 [[ -x "$sdk/emulator/emulator" ]] || fail 'Android emulator executable missing after SDK installation'
 if [[ -f "$ANDROID_AVD_HOME/$AVD_NAME.ini" ]]; then log "AVD already exists: $AVD_NAME"; return; fi
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
 if ((EMULATOR_HEADLESS)); then flags+=(-no-window -no-audio); fi
 nohup "$exe" "${flags[@]}" > "$log_file" 2>&1 < /dev/null &
 log "Emulator launched (pid=$!, log=$log_file). Hardware virtualization and host graphics are required for acceleration."
}
emulator_remove() {
 android_emulator_ready
 local avd="$ROOT/kotlin/android-sdk/cmdline-tools/latest/bin/avdmanager" sdk="$ROOT/kotlin/android-sdk" package
 if [[ -f "$ANDROID_AVD_HOME/$AVD_NAME.ini" ]]; then "$avd" delete avd -n "$AVD_NAME"; log "AVD removed: $AVD_NAME"
 else log "AVD absent: $AVD_NAME"; fi
 if ((PURGE_EMULATOR_PACKAGES)); then
  if find "$ANDROID_AVD_HOME" -maxdepth 1 -name '*.ini' -print -quit | grep -q .; then
   fail 'Other AVDs exist; only selected AVD deleted. Refusing to uninstall shared system image/emulator.'
  fi
  package="$(android_image_package)"
  "$sdk/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$sdk" --uninstall "$package" emulator
  log 'Emulator package and selected system image removed (ADB retained).'
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
 local n sub confirm yn choice label
 echo "=== Portable Build Kit: ${LANG_NAME} ==="
 echo '1. 설치 (Install)'
 echo '2. 환경설정 (Configure)'
 echo '3. 최신화 (Update)'
 echo '4. 초기화 (Reset)'
 echo '0. 종료'
 read -r -p 'Choose: ' n
 case "$n" in
  1)
   ACTION=install
   read -r -p 'If you have reviewed Android SDK licenses, accept? (yes/no): ' yn
   [[ "$yn" == yes ]] && ACCEPT_LICENSES=1;;
  2)
   ACTION=configure
   echo 'Configuration: 1 verify | 2 session env | 3 global-on | 4 global-off'
   echo '               5 prime dependencies | 6 offline-check | 7 list | 8 optional features | 0 back'
   read -r -p 'Choice: ' sub
   case "$sub" in
    1) MODE=verify;;2) MODE=env;;3) MODE=global-on;;4) MODE=global-off;;5) MODE=prime;;6) MODE=offline-check;;7) MODE=list;;
    8)
     echo 'Android emulator: 1 install | 2 list | 3 start | 4 remove | 0 back'
     read -r -p 'Choice: ' choice
     case "$choice" in 1) OPERATION=install;;2) OPERATION=list;;3) OPERATION=start;;4) OPERATION=remove;;0) exit 0;;*) fail 'Invalid emulator choice';; esac
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
    0) exit 0;;
    *) fail 'Invalid config choice';;
   esac;;
  3)
   ACTION=update
   read -r -p 'If you have reviewed Android SDK licenses, accept? (yes/no): ' yn
   [[ "$yn" == yes ]] && ACCEPT_LICENSES=1;;
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
 if [[ "$FEATURE" == emulator ]]; then ACTION="emulator-${OPERATION}"
 elif [[ "$FEATURE" != none ]]; then fail "Unsupported feature for $LANG_NAME: $FEATURE"
 else ACTION="$MODE"; fi
fi
[[ "$ANDROID_API" =~ ^[0-9]+$ && "$BUILD_TOOLS" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$NDK_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Invalid Android package version'
[[ "$EMULATOR_ABI" == x86_64 || "$EMULATOR_ABI" == arm64-v8a ]] || fail 'Invalid emulator ABI'
[[ "$EMULATOR_FLAVOR" == default || "$EMULATOR_FLAVOR" == google_apis ]] || fail 'Invalid emulator flavor'
[[ "$AVD_NAME" =~ ^[A-Za-z][A-Za-z0-9_.-]{0,63}$ ]] || fail 'Invalid AVD name (ASCII letters/digits/._-)'
case "$ACTION" in
 install) install_kotlin;;
 verify) activate; do_verify;;
 update) do_update;;
 prime) activate; do_prime;;
 offline-check) activate; do_offline;;
 env) printf 'Run in current shell: source %q\n' "$ROOT/$LANG_NAME.sh";;
 global-on) global_on;;
 global-off) global_off;;
 list) do_list;;
 emulator-install) emulator_install;;
 emulator-list) emulator_list;;
 emulator-start) emulator_start;;
 emulator-remove) emulator_remove;;
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
