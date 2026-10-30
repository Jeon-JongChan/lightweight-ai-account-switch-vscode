#!/usr/bin/env bash
# Node.js - 독립 실행 스크립트 (Linux, Facade 4-액션 내장).
# 이 파일 하나만 복사해도 설치·환경설정(검증/세션/전역/prime/offline-check/vue-init)·최신화·초기화가 모두 동작한다.
#   대화형 메뉴: bash nodejs.sh
#   비대화형:    bash nodejs.sh install | configure --mode verify|env|global-on|global-off|prime|offline-check|list|run | update | reset --yes | vue-init
#   세션 적용:   source nodejs.sh
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LANG_NAME=nodejs
STATE="$ROOT/$LANG_NAME/_state"
pbk_path() { local p; for p in "$@"; do if [[ -d "$p" ]]; then chmod +x "$p"/* 2>/dev/null || true; PATH="$p:$PATH"; fi; done; export PATH; }
activate() {
 export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
 export npm_config_cache="$ROOT/nodejs/npm-cache" npm_config_prefix="$ROOT/nodejs/npm-global" npm_config_userconfig="$ROOT/nodejs/npmrc" COREPACK_HOME="$ROOT/nodejs/corepack" npm_config_update_notifier=false npm_config_unsafe_perm=true
 pbk_path "$ROOT/nodejs/node/bin"
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
case "$(uname -s)" in Linux) ;; *) fail 'This .sh supports Linux. For Windows use nodejs.ps1.';; esac
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
NODE_MAJOR=24 RUN_ARGS=()
while (($#)); do
 case "$1" in
  menu|install|configure|update|reset|verify|prime|offline-check|env|global-on|global-off|remove|list|run|vue-init) ACTION="$1"; shift;;
  --mode) MODE="${2:?}"; shift 2;;
  --feature) FEATURE="${2:?}"; shift 2;;
  --operation) OPERATION="${2:?}"; shift 2;;
  --scope) SCOPE="${2:?}"; shift 2;;
  --yes) YES=1; shift;;
  --project) PROJECT="${2:?}"; shift 2;;
  --node-major) NODE_MAJOR="${2:?}"; shift 2;;
  --accept-android-licenses) shift;;
  --) shift; RUN_ARGS=("$@"); break;;
  -h|--help) echo "Usage: bash $LANG_NAME.sh [menu|install|configure|update|reset|vue-init] [options]"; exit 0;;
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
 [[ -d "$ROOT/nodejs/projects" ]] || return 0
 for store in "$ROOT/nodejs/projects"/*; do
  [[ -f "$store/project.txt" ]] || continue
  proj="$(cat "$store/project.txt")"
  [[ "$proj" == /* ]] || proj="$DEFAULT_PROJECT/$proj"
  link="$proj/node_modules"; target="$store/node_modules"
  if [[ -L "$link" && "$(readlink -f "$link")" == "$target" ]]; then rm -- "$link"
  elif [[ -f "$link/.pbk-managed" ]]; then PROJECT="$proj" node_check_link "$store"; rm_tree "$link"; fi
 done
}
install_nodejs() {
 [[ -x "$ROOT/nodejs/node/bin/node" ]] && { log 'node already present'; return; }
 local sums filename expected tmp
 sums="$(curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/SHASUMS256.txt")"
 filename="$(printf '%s\n' "$sums" | awk -v m="$NODE_MAJOR" -v a="$([[ "$host_arch" == x64 ]] && echo x64 || echo arm64)" '$2 ~ ("^node-v" m "[.]" ) && $2 ~ ("-linux-" a "[.]tar[.]gz$") {print $2;exit}')"
 [[ -n "$filename" ]] || fail "No Node LTS archive for Linux $host_arch"
 expected="$(printf '%s\n' "$sums" | awk -v f="$filename" '$2==f {print $1;exit}')"
 tmp="$STATE/$filename"; fetch "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/$filename" "$tmp"; sha_check "$tmp" "$expected"
 ensure_dir "$ROOT/nodejs/node"; extract_one "$tmp" "$ROOT/nodejs/node"; rm -f "$tmp"
}
do_verify() { [[ -x "$ROOT/nodejs/node/bin/node" ]] && "$ROOT/nodejs/node/bin/node" --version && "$ROOT/nodejs/node/bin/npm" --version || fail 'Node.js verification failed'; }
do_update() {
 local old="$STATE/update-backup-nodejs" latest latest_version
 [[ -x "$ROOT/nodejs/node/bin/node" ]] || fail 'Node.js missing. Run install first.'
 latest="$(curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/SHASUMS256.txt" | grep -oE 'node-v[0-9]+\.[0-9]+\.[0-9]+-linux-' | head -n 1 || true)"
 latest_version="${latest#node-}"; latest_version="${latest_version%-linux-}"
 [[ "$latest_version" == v* ]] || fail 'Cannot resolve latest Node.js version'
 if [[ "$("$ROOT/nodejs/node/bin/node" --version)" == "$latest_version" ]]; then log "Node.js already at $latest_version"; return; fi
 [[ ! -e "$old" ]] || fail "Incomplete previous update exists: $old"
 ensure_dir "$STATE"; mv "$ROOT/nodejs/node" "$old"
 if (install_nodejs); then rm_tree "$old"; else
  rm_tree "$ROOT/nodejs/node"; mv "$old" "$ROOT/nodejs/node"; fail 'Node.js upgrade failed; previous toolchain restored'
 fi
}
vue_init() {
 install_nodejs; activate
 [[ -d "$PROJECT" ]] || fail "Project directory not found: $PROJECT"
 [[ -z "$(find "$PROJECT" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail "Vue scaffold target must be empty: $PROJECT"
 (cd "$PROJECT" && npm create vue@latest -- --typescript .)
 log 'Vue scaffold complete. Run nodejs prime --project <path> to capture dependencies.'
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
     echo 'Vue project: 1 initialize (empty target folder) | 0 back'
     read -r -p 'Choice: ' choice
     case "$choice" in 1) FEATURE=vue; OPERATION=init;;0) exit 0;;*) fail 'Invalid Vue choice';; esac;;
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
 if [[ "$FEATURE" == vue && "$OPERATION" == init ]]; then ACTION=vue-init
 elif [[ "$FEATURE" != none ]]; then fail "Unsupported feature for $LANG_NAME: $FEATURE"
 else ACTION="$MODE"; fi
fi
case "$ACTION" in
 install) install_nodejs;;
 verify) activate; do_verify;;
 update) do_update;;
 prime) activate; node_prime; (cd "$PROJECT" && npm run build --if-present);;
 offline-check) activate; node_offline_prepare; (cd "$PROJECT" && npm_config_offline=true npm run build --if-present);;
 env) printf 'Run in current shell: source %q\n' "$ROOT/$LANG_NAME.sh";;
 global-on) global_on;;
 global-off) global_off;;
 list) do_list;;
 vue-init) vue_init;;
 reset|remove)
  if [[ "$ACTION" == reset && "$SCOPE" != env && "$YES" != 1 ]]; then fail 'Reset deletes toolchains; pass --yes after reviewing scope.'; fi
  case "$SCOPE" in
   all) global_off;;
   env) global_off; exit 0;;
   tools) [[ ! -f "$STATE/global-bash-enabled" ]] || fail 'Restore globals first or use --scope all';;
   *) fail 'Invalid reset scope';;
  esac
  cleanup_node_links
  rm_tree "$ROOT/$LANG_NAME"; log "Removed $LANG_NAME";;
 run) activate; ((${#RUN_ARGS[@]})) || fail 'run requires -- command [args]'; "${RUN_ARGS[@]}";;
 *) fail "Unsupported action: $ACTION";;
esac
