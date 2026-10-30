#!/usr/bin/env bash
# Go - 독립 실행 스크립트 (Linux, Facade 4-액션 내장).
# 이 파일 하나만 복사해도 설치·환경설정(검증/세션/전역/prime/offline-check)·최신화·초기화가 모두 동작한다.
#   대화형 메뉴: bash go.sh
#   비대화형:    bash go.sh install | configure --mode verify|env|global-on|global-off|prime|offline-check|list|run | update | reset --yes
#   세션 적용:   source go.sh
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LANG_NAME=go
STATE="$ROOT/$LANG_NAME/_state"
pbk_path() { local p; for p in "$@"; do if [[ -d "$p" ]]; then chmod +x "$p"/* 2>/dev/null || true; PATH="$p:$PATH"; fi; done; export PATH; }
activate() {
 export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
 export GOROOT="$ROOT/go/sdk" GOPATH="$ROOT/go/path" GOMODCACHE="$ROOT/go/path/pkg/mod" GOCACHE="$ROOT/go/cache" GOENV="$ROOT/go/goenv" GOTOOLCHAIN=local
 pbk_path "$ROOT/go/sdk/bin"
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
case "$(uname -s)" in Linux) ;; *) fail 'This .sh supports Linux. For Windows use go.ps1.';; esac
case "$(uname -m)" in x86_64|amd64) host_arch=x64; go_arch=amd64;; aarch64|arm64) host_arch=aarch64; go_arch=arm64;; *) fail "Unsupported CPU $(uname -m)";; esac
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
GO_VERSION=1.27.2 GO_VERSION_EXPLICIT=0 RUN_ARGS=()
while (($#)); do
 case "$1" in
  menu|install|configure|update|reset|verify|prime|offline-check|env|global-on|global-off|remove|list|run) ACTION="$1"; shift;;
  --mode) MODE="${2:?}"; shift 2;;
  --feature) FEATURE="${2:?}"; shift 2;;
  --operation) OPERATION="${2:?}"; shift 2;;
  --scope) SCOPE="${2:?}"; shift 2;;
  --yes) YES=1; shift;;
  --project) PROJECT="${2:?}"; shift 2;;
  --go-version) GO_VERSION="${2:?}"; GO_VERSION_EXPLICIT=1; shift 2;;
  --accept-android-licenses) shift;;
  --) shift; RUN_ARGS=("$@"); break;;
  -h|--help) echo "Usage: bash $LANG_NAME.sh [menu|install|configure|update|reset] [options]"; exit 0;;
  *) fail "Unknown option or action: $1";;
 esac
done
PROJECT="$(cd "$PROJECT" 2>/dev/null && pwd)" || fail "Project directory does not exist: $PROJECT"

install_go() {
 [[ -x "$ROOT/go/sdk/bin/go" ]] && { log 'go already present'; return; }
 requires awk
 local name="go${GO_VERSION}.linux-${go_arch}.tar.gz" meta checksum tmp
 tmp="$STATE/$name"
 meta="$(curl -fsSL 'https://go.dev/dl/?mode=json&include=all')"
 checksum="$(awk -F'"' -v n="$name" 'index($0,"\"filename\"") {hit=(index($0,n)>0)} hit && index($0,"\"sha256\"") {print $4;exit}' <<<"$meta")"
 [[ "${#checksum}" -eq 64 ]] || fail "Cannot validate Go checksum for $name"
 fetch "https://go.dev/dl/$name" "$tmp"; sha_check "$tmp" "$checksum"
 ensure_dir "$ROOT/go/sdk"; extract_one "$tmp" "$ROOT/go/sdk"; rm -f "$tmp"
 log 'Installed Go.'
}
latest_go_version() {
 local version
 version="$(curl -fsSL 'https://go.dev/dl/?mode=json' | grep -m1 -oE '"version"[[:space:]]*:[[:space:]]*"go[0-9]+\.[0-9]+(\.[0-9]+)?"' | grep -oE 'go[0-9]+\.[0-9]+(\.[0-9]+)?' || true)"
 [[ -n "$version" ]] || fail 'Unable to resolve latest stable Go version'
 printf '%s' "${version#go}"
}
do_verify() { [[ -x "$ROOT/go/sdk/bin/go" ]] && go version || fail 'Go verification failed'; }
do_update() {
 local old="$STATE/update-backup-go"
 [[ -x "$ROOT/go/sdk/bin/go" ]] || fail 'Go missing. Run install first.'
 ((GO_VERSION_EXPLICIT)) || GO_VERSION="$(latest_go_version)"
 if [[ "$("$ROOT/go/sdk/bin/go" version)" == *"go${GO_VERSION} "* ]]; then log "Go already at $GO_VERSION"; return; fi
 [[ ! -e "$old" ]] || fail "Incomplete previous update exists: $old"
 ensure_dir "$STATE"; mv "$ROOT/go/sdk" "$old"
 if (install_go); then rm_tree "$old"; else
  rm_tree "$ROOT/go/sdk"; mv "$old" "$ROOT/go/sdk"; fail 'Go upgrade failed; previous toolchain restored'
 fi
}
do_prime() { [[ -x "$ROOT/go/sdk/bin/go" ]] || fail 'Go missing'; [[ -f "$PROJECT/go.mod" ]] || fail 'go.mod missing'; (cd "$PROJECT" && go mod download && go test ./"."".".); }
do_offline() { [[ -x "$ROOT/go/sdk/bin/go" ]] || fail 'Go missing'; [[ -f "$PROJECT/go.mod" ]] || fail 'go.mod missing'; (cd "$PROJECT" && GOPROXY=off GOSUMDB=off go test ./...); }
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
 local n sub confirm
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
   case "$sub" in 1) MODE=verify;;2) MODE=env;;3) MODE=global-on;;4) MODE=global-off;;5) MODE=prime;;6) MODE=offline-check;;7) MODE=list;;8) echo 'No optional features for this language.'; exit 0;;0) exit 0;;*) fail 'Invalid config choice';; esac;;
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
 [[ "$FEATURE" == none ]] || fail "Unsupported feature for $LANG_NAME: $FEATURE"
 ACTION="$MODE"
fi
case "$ACTION" in
 install) install_go;;
 verify) activate; do_verify;;
 update) do_update;;
 prime) activate; do_prime;;
 offline-check) activate; do_offline;;
 env) printf 'Run in current shell: source %q\n' "$ROOT/$LANG_NAME.sh";;
 global-on) global_on;;
 global-off) global_off;;
 list) do_list;;
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
