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
