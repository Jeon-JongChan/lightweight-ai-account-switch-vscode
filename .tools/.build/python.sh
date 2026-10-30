#!/usr/bin/env bash
# Python (uv) - 독립 실행 스크립트 (Linux, Facade 4-액션 내장).
# 이 파일 하나만 복사해도 설치·환경설정(검증/세션/전역/prime/offline-check)·최신화·초기화가 모두 동작한다.
#   대화형 메뉴: bash python.sh
#   비대화형:    bash python.sh install | configure --mode verify|env|global-on|global-off|prime|offline-check|list|run | update | reset --yes
#   세션 적용:   source python.sh
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LANG_NAME=python
STATE="$ROOT/$LANG_NAME/_state"
pbk_path() { local p; for p in "$@"; do if [[ -d "$p" ]]; then chmod +x "$p"/* 2>/dev/null || true; PATH="$p:$PATH"; fi; done; export PATH; }
activate() {
 export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
 # ponytail: UV_MANAGED_PYTHON conflicts with UV_PYTHON_PREFERENCE on uv>=0.13
 export UV_CACHE_DIR="$ROOT/python/cache" UV_PYTHON_INSTALL_DIR="$ROOT/python/runtimes" UV_PYTHON_BIN_DIR="$ROOT/python/bin" UV_PYTHON_PREFERENCE=only-managed UV_LINK_MODE=copy UV_TOOL_DIR="$ROOT/python/tools" UV_TOOL_BIN_DIR="$ROOT/python/bin" PIP_CACHE_DIR="$ROOT/python/pip-cache" PYTHONNOUSERSITE=1
 unset UV_MANAGED_PYTHON
 pbk_path "$ROOT/python/bin"
 local d
 if [[ -d "$ROOT/python/runtimes" ]]; then
  for d in "$ROOT/python/runtimes"/*/bin; do
   if [[ -d "$d" ]]; then pbk_path "$d"; fi
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
case "$(uname -s)" in Linux) ;; *) fail 'This .sh supports Linux. For Windows use python.ps1.';; esac
case "$(uname -m)" in x86_64|amd64) host_arch=x64;; aarch64|arm64) host_arch=aarch64;; *) fail "Unsupported CPU $(uname -m)";; esac
fetch() { requires curl; ensure_dir "$(dirname "$2")"; curl --fail --location --retry 3 --connect-timeout 20 --output "$2" "$1"; }

DEFAULT_PROJECT="$ROOT"; [[ "$(basename "$ROOT")" == ".build" ]] && DEFAULT_PROJECT="$(dirname "$ROOT")"
ACTION=menu MODE=verify FEATURE=none OPERATION= SCOPE=all YES=0 PROJECT="$DEFAULT_PROJECT"
PYTHON_VERSION=3.13 RUN_ARGS=()
while (($#)); do
 case "$1" in
  menu|install|configure|update|reset|verify|prime|offline-check|env|global-on|global-off|remove|list|run) ACTION="$1"; shift;;
  --mode) MODE="${2:?}"; shift 2;;
  --feature) FEATURE="${2:?}"; shift 2;;
  --operation) OPERATION="${2:?}"; shift 2;;
  --scope) SCOPE="${2:?}"; shift 2;;
  --yes) YES=1; shift;;
  --project) PROJECT="${2:?}"; shift 2;;
  --python-version) PYTHON_VERSION="${2:?}"; shift 2;;
  --accept-android-licenses) shift;;
  --) shift; RUN_ARGS=("$@"); break;;
  -h|--help) echo "Usage: bash $LANG_NAME.sh [menu|install|configure|update|reset] [options]"; exit 0;;
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
uv_install() {
 ensure_dir "$ROOT/python/bin"
 fetch 'https://astral.sh/uv/install.sh' "$STATE/uv-install.sh"
 UV_UNMANAGED_INSTALL="$ROOT/python/bin" sh "$STATE/uv-install.sh"
}
do_install() {
 [[ -x "$ROOT/python/bin/uv" ]] || uv_install
 activate; "$ROOT/python/bin/uv" python install "$PYTHON_VERSION" --default
 relativize_python_links
 activate
 command -v python >/dev/null 2>&1 && python --version || fail 'Portable python executable missing from python'
}
do_verify() { [[ -x "$ROOT/python/bin/uv" ]] && uv python list --only-installed && python --version || fail 'Python verification failed'; }
do_update() {
 [[ -x "$ROOT/python/bin/uv" ]] || fail 'Python/uv missing. Run install first.'
 uv_install
 activate; uv python install "$PYTHON_VERSION" --default
 relativize_python_links
 log 'Python updated within requested version line. Review existing venv pins.'
}
do_prime() {
 [[ -x "$ROOT/python/bin/uv" ]] || fail 'Python/uv missing'
 local py_env="$ROOT/python/envs/$(project_key)"
 export UV_PROJECT_ENVIRONMENT="$py_env"
 cd "$PROJECT"
 if [[ -f uv.lock ]]; then uv sync --locked
 elif [[ -f pyproject.toml ]]; then uv sync
 elif [[ -f requirements.txt ]]; then uv venv --python "$PYTHON_VERSION" --allow-existing "$py_env"; uv pip install --python "$py_env/bin/python" -r requirements.txt
 else fail 'Requires uv.lock, pyproject.toml or requirements.txt'; fi
}
do_offline() {
 [[ -x "$ROOT/python/bin/uv" ]] || fail 'Python/uv missing'
 local py_env="$ROOT/python/envs/$(project_key)"
 export UV_PROJECT_ENVIRONMENT="$py_env"
 cd "$PROJECT"
 if [[ -f uv.lock ]]; then uv sync --offline --locked
 elif [[ -f requirements.txt ]]; then uv pip install --offline --python "$py_env/bin/python" -r requirements.txt
 elif [[ -f pyproject.toml ]]; then uv sync --offline
 else fail 'Requires uv.lock, pyproject.toml or requirements.txt'; fi
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
 install) do_install;;
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
