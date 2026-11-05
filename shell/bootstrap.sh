#!/usr/bin/env bash
# Sourced interface (Bash >=4.4, Linux): caller supplies PROJECT, TMP=$PROJECT/tmp,
# fail <fixed_reason> (exits) and emit <fixed_event>. No work occurs on source.
# bootstrap_interactive: local /dev/tty consent, optional installs, saves JSON.
# load_install_config: validate/load JSON, export five lower-case fields plus
# MAGPIE_BIN, CONFIG_HOME, PLUGIN_PATH, BUN_PATH, HOST_PATH. Never source JSON.
# environment_check: offline dependencies + saved paths/package/runtime hashes;
# does not log in, install, open a browser, or execute Magpie/plugin/Bun code.

source "${BASH_SOURCE[0]%/*}/install-deps.sh"

_bootstrap_dependencies() {
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
        fail bash_4_4_required
    fi
    local tool
    # jq is needed by the caller's emit/fail implementation too.
    if ! command -v jq >/dev/null 2>&1; then
        printf '%s\n' '{"event":"stopped","reason":"missing_dependency_jq"}' >&2
        exit 1
    fi
    for tool in uname curl jq gpg flock timeout setsid sha256sum sync realpath stat mktemp mkdir chmod mv rm cp dd env od tr grep cmp mkfifo date sleep unzip; do
        command -v "$tool" >/dev/null 2>&1 || fail "missing_dependency_$tool"
    done
    [[ $(uname -s 2>/dev/null) == Linux ]] || fail linux_required
}

_bootstrap_layout() {
    [[ ${PROJECT:-} == /* && ${TMP:-} == "$PROJECT/tmp" ]] || fail invalid_project_tmp
    [[ $(realpath -e -- "$PROJECT" 2>/dev/null) == "$PROJECT" ]] || fail invalid_project_root
    [[ ! -L $TMP ]] || fail unsafe_install_tmp
    if [[ -e $TMP ]]; then
        [[ -d $TMP && $(realpath -e -- "$TMP" 2>/dev/null) == "$TMP" && $(stat -c %u -- "$TMP") == "$UID" ]] || fail unsafe_install_tmp
        [[ $((8#$(stat -c %a -- "$TMP") & 077)) == 0 ]] || fail insecure_install_tmp_permissions
    fi
}

_bootstrap_absolute() {
    local value=$1
    [[ $value == /* && $value != / && $value != *[[:cntrl:]]* && $value != */ && ${#value} -le 4096 ]] || fail invalid_install_path
    [[ $(realpath -m -- "$value" 2>/dev/null) == "$value" ]] || fail noncanonical_install_path
}

_bootstrap_hash() {
    local path=$1 expected=$2 actual
    [[ -f $path && ! -L $path && -r $path ]] || return 1
    actual=$(timeout --kill-after=2s 30s sha256sum -- "$path" 2>/dev/null) || return 1
    [[ ${actual%% *} == "$expected" ]]
}

_bootstrap_magpie_hash() {
    printf '%s' f730747a84cc3932da6f6a84926cf428a10ee2224c5c6dfbf37df9dbfd4dffb6
}
_bootstrap_plugin_hash() {
    printf '%s' df2eb4515bd4dd3a863006023385038a8c79eb09d1efe849fd14af979b810d1d
}
_bootstrap_bun_hash() {
    printf '%s' 10702245766b225e70bbf6235fd6b47214fd94b4760d00ffaed8ab0df57ac235
}
_bootstrap_bun_archive_hash() {
    printf '%s' e0446eb55995772eb9894bebae9a6be368d985a8b9271ee124486f9946eedd76
}
_bootstrap_host_hash() {
    printf '%s' 25ef7cf0d2813cc25a2e3675c28b5fa9ce9ec87f1b5a621803a193ab3929dbac
}
_bootstrap_plugin_path() {
    printf '%s/magpie/plugins/node_modules/@magpie-community/opencode-trae-auth/index.mjs' "$config_home"
}

load_install_config() {
    _bootstrap_dependencies
    _bootstrap_layout
    local config=$TMP/shell-install.json values
    [[ -f $config && ! -L $config && $(stat -c %u -- "$config") == "$UID" && $(stat -c %a -- "$config") == 600 ]] || fail install_config_missing_or_insecure
    values=$(jq -er '
        select(type=="object") |
        select((keys|sort)==(["magpie_bin","config_home","plugin_path","bun_path","host_path"]|sort)) |
        [.magpie_bin,.config_home,.plugin_path,.bun_path,.host_path] |
        select(all(.[]; type=="string" and startswith("/") and length>1 and length<=4096 and (test("[\\x00-\\x1f\\x7f]")|not))) | .[]
        ' "$config" 2>/dev/null) || fail invalid_install_config
    local fields=()
    mapfile -t fields <<< "$values"
    [[ ${#fields[@]} == 5 ]] || fail invalid_install_config
    magpie_bin=${fields[0]} config_home=${fields[1]} plugin_path=${fields[2]} bun_path=${fields[3]} host_path=${fields[4]}
    local path
    for path in "$magpie_bin" "$config_home" "$plugin_path" "$bun_path" "$host_path"; do _bootstrap_absolute "$path"; done
    [[ $plugin_path == "$(_bootstrap_plugin_path)" ]] || fail plugin_path_not_native_config
    export magpie_bin config_home plugin_path bun_path host_path
    export MAGPIE_BIN=$magpie_bin CONFIG_HOME=$config_home PLUGIN_PATH=$plugin_path BUN_PATH=$bun_path HOST_PATH=$host_path
}

_bootstrap_check_paths() {
    local path
    for path in "$magpie_bin" "$config_home" "$plugin_path" "$bun_path" "$host_path"; do _bootstrap_absolute "$path"; done
    [[ $plugin_path == "$(_bootstrap_plugin_path)" ]] || fail plugin_path_not_native_config
    [[ -f $magpie_bin && -x $magpie_bin && ! -L $magpie_bin ]] || fail magpie_executable_missing
    _bootstrap_hash "$magpie_bin" "$(_bootstrap_magpie_hash)" || fail pinned_magpie_mismatch
    [[ -d $config_home && ! -L $config_home ]] || fail magpie_config_home_missing
    [[ -f $plugin_path && ! -L $plugin_path ]] || fail native_trae_plugin_missing
    _bootstrap_hash "$plugin_path" "$(_bootstrap_plugin_hash)" || fail pinned_plugin_mismatch
    local metadata=${plugin_path%/*}/package.json
    [[ -f $metadata && ! -L $metadata ]] || fail native_trae_package_missing
    jq -e '.name=="@magpie-community/opencode-trae-auth" and .version=="0.2.26" and (.main=="./index.mjs" or .main=="index.mjs")' "$metadata" >/dev/null 2>&1 || fail native_trae_package_pin_mismatch
    [[ -x $bun_path ]] && _bootstrap_hash "$bun_path" "$(_bootstrap_bun_hash)" || fail pinned_bun_missing_or_mismatch
    _bootstrap_hash "$host_path" "$(_bootstrap_host_hash)" || fail pinned_host_missing_or_mismatch
}

environment_check() {
    load_install_config
    _bootstrap_check_paths
    emit environment_ready
}

_bootstrap_open_tty() {
    local name
    # Presence counts, even an empty marker. Never unset bridge variables.
    for name in ${!LARK_CHANNEL@} LARKSUITE_CLI_CONFIG_DIR; do
        [[ ! -v $name ]] || fail bootstrap_requires_local_terminal_not_bridge
    done
    [[ $- != *x* && -z ${BASH_XTRACEFD:-} ]] || fail bootstrap_disable_shell_tracing
    { exec {BOOTSTRAP_TTY}<>/dev/tty; } 2>/dev/null || fail bootstrap_requires_local_terminal
    [[ -t $BOOTSTRAP_TTY ]] || fail bootstrap_requires_local_terminal
}

_bootstrap_ask() {
    local target=$1 prompt=$2 default=${3:-} answer
    printf '\n%s' "$prompt" >&"$BOOTSTRAP_TTY"
    [[ -z $default ]] || printf ' [%s]' "$default" >&"$BOOTSTRAP_TTY"
    printf ': ' >&"$BOOTSTRAP_TTY"
    IFS= read -r -u "$BOOTSTRAP_TTY" answer || fail bootstrap_input_closed
    [[ -n $answer ]] || answer=$default
    [[ -n $answer && $answer != *[[:cntrl:]]* ]] || fail bootstrap_invalid_input
    printf -v "$target" '%s' "$answer"
}
_bootstrap_confirm() {
    local response
    _bootstrap_ask response "$1 Press Enter or type yes to consent; type no to cancel" YES
    case ${response,,} in
        y|yes) ;;
        *) fail bootstrap_consent_declined ;;
    esac
}
_bootstrap_ask_path() {
    _bootstrap_ask "$1" "$2 (press Enter to use the displayed default)" "${3:-}"
    _bootstrap_absolute "${!1}"
    _bootstrap_confirm "Use ${!1}?"
}

_bootstrap_prepare_directory() {
    local directory=$1 parent
    _bootstrap_absolute "$directory"
    if [[ ! -e $directory && ! -L $directory ]]; then
        parent=${directory%/*}
        [[ -n $parent ]] || parent=/
        while [[ ! -e $parent && $parent != / ]]; do parent=${parent%/*}; [[ -n $parent ]] || parent=/; done
        [[ -d $parent && ! -L $parent && -w $parent && $(stat -c %u -- "$parent") == "$UID" && $((8#$(stat -c %a -- "$parent") & 022)) == 0 ]] || fail unsafe_install_parent
        _bootstrap_confirm "Create missing directory $directory?"
        mkdir -p -m 700 -- "$directory" || fail install_directory_creation_failed
    fi
    [[ -d $directory && ! -L $directory && -w $directory && $(realpath -e -- "$directory") == "$directory" && $(stat -c %u -- "$directory") == "$UID" && $((8#$(stat -c %a -- "$directory") & 022)) == 0 ]] || fail unsafe_install_parent
}

_bootstrap_fetch() {
    local url=$1 output=$2 rc=0 code
    [[ $url =~ ^https://[^/@[:space:]]+(/[^[:space:]]*)?$ && $url != *'"'* && $url != *'\\'* ]] || fail invalid_artifact_url
    local args=(-q -4 --fail --silent --show-error --location --proto '=https' --proto-redir '=https'
        --connect-timeout 8 --max-time 90 --max-filesize 268435456 --output "$output" --url "$url")
    timeout --kill-after=2s 95s curl "${args[@]}" >/dev/null 2>&1 || rc=$?
    if (( rc != 0 )); then
        case $rc in
            5|6|7|18|28|52|55|56|124)
                code=$(timeout --kill-after=2s 17s curl -q -4 -sS --head --location --proto '=https' --proto-redir '=https' --connect-timeout 5 --max-time 15 --output /dev/null --write-out '%{http_code}' --url "$url" 2>/dev/null) || fail runtime_download_unavailable
                [[ $code == 200 ]] || fail runtime_download_unavailable
                timeout --kill-after=2s 95s curl "${args[@]}" >/dev/null 2>&1 || fail runtime_download_unavailable ;;
            *) fail runtime_download_rejected ;;
        esac
    fi
}

_bootstrap_install_asset() {
    local source=$1 destination=$2 expected=$3 mode=$4
    _bootstrap_hash "$source" "$expected" || fail runtime_artifact_checksum_mismatch
    [[ ! -e $destination && ! -L $destination ]] || fail runtime_install_would_overwrite
    _bootstrap_prepare_directory "${destination%/*}"
    (
        set -o noclobber
        umask 077
        exec {asset_fd}>"$destination" || exit 1
        dd if="$source" status=none >&"$asset_fd" || exit 1
        chmod "$mode" -- "$destination" && sync -f "$destination"
    ) >/dev/null 2>&1 || fail runtime_install_failed_inspect_new_target
    _bootstrap_hash "$destination" "$expected" || fail runtime_installed_checksum_mismatch
}

_bootstrap_download_magpie() {
    local destination=$1 work=$2 url expected rc=0 code
    [[ ! -e $destination && ! -L $destination ]] || fail magpie_install_would_overwrite
    local parent=${destination%/*}
    [[ -d $parent && -w $parent && $(stat -c %u -- "$parent") == "$UID" && $((8#$(stat -c %a -- "$parent") & 022)) == 0 ]] || fail magpie_install_parent_requires_manual_setup
    _bootstrap_ask url 'HTTPS URL for the pinned Magpie v0.1.1364 Linux executable' 'https://github.com/yetone/magpie-releases/releases/download/v0.1.1364/magpie-cli-linux-amd64'
    [[ $url =~ ^https://[^/@[:space:]]+(/[^[:space:]]*)?$ && $url != *'"'* && $url != *'\'* ]] || fail invalid_magpie_artifact_url
    _bootstrap_ask expected 'Pinned SHA256 from the verified release manifest' "$(_bootstrap_magpie_hash)"
    [[ $expected =~ ^[[:xdigit:]]{64}$ ]] || fail invalid_magpie_artifact_sha256
    expected=${expected,,}
    [[ $expected == "$(_bootstrap_magpie_hash)" ]] || fail unsupported_magpie_artifact_manifest
    _bootstrap_confirm "Download, verify and install the executable at $destination?"
    # New empty artifact directory; never execute from it. Disable curlrc and
    # constrain redirects to HTTPS. Download and every probe have outer bounds.
    local artifact_dir
    artifact_dir=$(mktemp -d "$work/artifact.XXXXXXXX") || fail bootstrap_temporary_failed
    local args=(-q -4 --fail --silent --show-error --location --proto '=https' --proto-redir '=https'
        --connect-timeout 8 --max-time 90 --max-filesize 268435456 --output "$artifact_dir/magpie" --url "$url")
    timeout --kill-after=2s 95s curl "${args[@]}" >/dev/null 2>&1 || rc=$?
    if (( rc != 0 )); then
        case $rc in
            5|6|7|18|28|52|55|56|124)
                code=$(timeout --kill-after=2s 17s curl -q -4 -sS --head --location --proto '=https' --proto-redir '=https' --connect-timeout 5 --max-time 15 --output /dev/null --write-out '%{http_code}' --url "$url" 2>/dev/null) || fail magpie_download_unavailable
                [[ $code == 200 ]] || fail magpie_download_unavailable
                timeout --kill-after=2s 95s curl "${args[@]}" >/dev/null 2>&1 || fail magpie_download_unavailable ;;
            *) fail magpie_download_rejected ;;
        esac
    fi
    _bootstrap_hash "$artifact_dir/magpie" "$expected" || fail magpie_artifact_checksum_mismatch
    # Require ELF magic; an authenticated shell installer is still not run.
    local magic
    magic=$(dd if="$artifact_dir/magpie" bs=1 count=4 status=none 2>/dev/null) || fail magpie_artifact_invalid
    [[ $magic == $'\x7fELF' ]] || fail magpie_artifact_must_be_linux_executable
    # O_EXCL via noclobber: an existing target (including a dangling symlink)
    # is never opened for truncation. Failures can leave a partial NEW file;
    # inspect/remove it manually, never silently replace it on a retry.
    (
        set -o noclobber
        umask 077
        exec {destination_fd}>"$destination" || exit 1
        dd if="$artifact_dir/magpie" status=none >&"$destination_fd" || exit 1
        chmod 700 -- "$destination" && sync -f "$destination"
    ) >/dev/null 2>&1 || fail magpie_install_failed_inspect_new_target
    _bootstrap_hash "$destination" "$expected" || fail magpie_installed_checksum_mismatch
    emit magpie_installed
}

_bootstrap_platform() {
    [[ $(uname -s) == Linux ]] || fail linux_required
    case $(uname -m) in x86_64|amd64) ;; *) fail pinned_runtime_requires_linux_x86_64;; esac
    local loader
    for loader in /lib/ld-musl-*.so.1; do
        [[ ! -e $loader ]] || fail pinned_runtime_requires_glibc
    done
}

_bootstrap_install_runtimes() {
    local work=$1 artifact_dir
    if [[ -e $bun_path || -L $bun_path ]]; then
        [[ -x $bun_path ]] && _bootstrap_hash "$bun_path" "$(_bootstrap_bun_hash)" || fail pinned_bun_missing_or_mismatch
    fi
    if [[ -e $host_path || -L $host_path ]]; then
        _bootstrap_hash "$host_path" "$(_bootstrap_host_hash)" || fail pinned_host_missing_or_mismatch
    fi
    if [[ ! -e $bun_path ]]; then
        _bootstrap_confirm "Download official Bun 1.4.4 (Linux x64 baseline), verify and install at $bun_path?"
        artifact_dir=$(mktemp -d "$work/bun.XXXXXXXX") || fail bootstrap_temporary_failed
        _bootstrap_fetch 'https://github.com/oven-sh/bun/releases/download/bun-v1.4.4/bun-linux-x64-baseline.zip' "$artifact_dir/bun.zip"
        _bootstrap_hash "$artifact_dir/bun.zip" "$(_bootstrap_bun_archive_hash)" || fail bun_archive_checksum_mismatch
        # Extract only the expected member to a private file, never archive paths.
        timeout --kill-after=2s 30s unzip -p "$artifact_dir/bun.zip" bun-linux-x64-baseline/bun > "$artifact_dir/bun" 2>/dev/null || fail bun_archive_invalid
        _bootstrap_install_asset "$artifact_dir/bun" "$bun_path" "$(_bootstrap_bun_hash)" 700
        emit bun_installed
    fi
    if [[ ! -e $host_path ]]; then
        _bootstrap_confirm "Download the pinned original Magpie host source, verify and install at $host_path?"
        artifact_dir=$(mktemp -d "$work/host.XXXXXXXX") || fail bootstrap_temporary_failed
        _bootstrap_fetch 'https://raw.githubusercontent.com/yetone/magpie/dd1e8822d916f8aeb085db4db93fc3d79e2263ed/internal/plugin/host.js' "$artifact_dir/host.js"
        _bootstrap_install_asset "$artifact_dir/host.js" "$host_path" "$(_bootstrap_host_hash)" 600
        emit host_installed
    fi
    [[ -x $bun_path ]] && _bootstrap_hash "$bun_path" "$(_bootstrap_bun_hash)" || fail pinned_bun_missing_or_mismatch
    _bootstrap_hash "$host_path" "$(_bootstrap_host_hash)" || fail pinned_host_missing_or_mismatch
}

_bootstrap_install_plugin() {
    local work=$1 package_dir=${plugin_path%/*}
    _bootstrap_absolute "$plugin_path"
    _bootstrap_hash "$magpie_bin" "$(_bootstrap_magpie_hash)" || fail pinned_magpie_mismatch
    [[ ! -e $package_dir && ! -L $package_dir ]] || fail native_plugin_existing_install_requires_manual_repair
    _bootstrap_confirm "Run native magpie plugin add @magpie-community/opencode-trae-auth@0.2.26 using config home $config_home? This updates the native plugin registry and downloads package dependencies."
    # Fresh private runtime cache avoids automatic retrieval of unknown host
    # assets and does not reuse the operator's native credentials/cache.
    mkdir -p -m 700 "$work/cache/magpie/bun/1.4.4" "$work/cache/magpie/plugin-host" "$work/native-tmp" || fail bootstrap_temporary_failed
    cp -- "$bun_path" "$work/cache/magpie/bun/1.4.4/magpie-bun" &&
        cp -- "$host_path" "$work/cache/magpie/plugin-host/host-25ef7cf0d281.js" || fail bootstrap_runtime_copy_failed
    local runtime=$work/cache/magpie/bun/1.4.4/magpie-bun
    chmod 700 "$runtime"
    _bootstrap_hash "$runtime" "$(_bootstrap_bun_hash)" && _bootstrap_hash "$work/cache/magpie/plugin-host/host-25ef7cf0d281.js" "$(_bootstrap_host_hash)" || fail bootstrap_runtime_copy_mismatch
    # No login, web, browser or arbitrary install script is invoked. Output is
    # discarded, not forwarded or retained as a possibly sensitive log.
    (cd "$PROJECT" && timeout --kill-after=5s 180s env -i PATH="$PATH" HOME="$HOME" \
        XDG_CONFIG_HOME="$config_home" XDG_CACHE_HOME="$work/cache" TMPDIR="$work/native-tmp" \
        BUN_INSTALL_CACHE_DIR="$work/cache/bun-packages" npm_config_cache="$work/cache/npm" \
        MAGPIE_BUN="$runtime" MAGPIE_NO_ACCOUNTS=1 BROWSER=/bin/false DISPLAY= WAYLAND_DISPLAY= \
        NO_COLOR=1 TERM=dumb "$magpie_bin" plugin add '@magpie-community/opencode-trae-auth@0.2.26') \
        </dev/null >/dev/null 2>&1 || fail native_plugin_install_unknown_reconcile_before_retry
    emit native_plugin_installed
}

_bootstrap_default_magpie() {
    local candidate
    if [[ -n ${magpie_bin:-} ]]; then
        printf '%s' "$magpie_bin"
        return
    fi
    candidate=$(type -P magpie || true)
    [[ -z $candidate ]] || candidate=$(realpath -e -- "$candidate" 2>/dev/null) || candidate=''
    printf '%s' "${candidate:-${MAGPIE_BIN_DIR:-$HOME/.local/bin}/magpie}"
}

bootstrap_interactive() (
    # Subshell owns descriptors, umask and cleanup without disturbing the caller.
    _bootstrap_open_tty
    _bootstrap_install_dependencies
    _bootstrap_dependencies
    _bootstrap_platform
    _bootstrap_layout
    umask 077
    local work='' lock_fd candidate config_new
    trap '[[ -z $work ]] || rm -rf -- "$work"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mkdir -p -m 700 -- "$TMP" || fail bootstrap_temporary_failed
    [[ ! -L $TMP/shell-bootstrap.lock ]] || fail unsafe_bootstrap_lock
    exec {lock_fd}>"$TMP/shell-bootstrap.lock" || fail bootstrap_lock_failed
    flock -n "$lock_fd" || fail bootstrap_busy
    work=$(mktemp -d "$TMP/bootstrap.XXXXXXXX") || fail bootstrap_temporary_failed
    if [[ -e $TMP/shell-install.json || -L $TMP/shell-install.json ]]; then
        load_install_config
        _bootstrap_confirm 'Replace the saved onboarding installation path selection (no existing executables/plugins will be overwritten)?'
    fi
    candidate=$(_bootstrap_default_magpie)
    _bootstrap_ask_path magpie_bin 'Absolute path to the existing or new Magpie executable' "$candidate"
    _bootstrap_prepare_directory "${magpie_bin%/*}"
    if [[ -e $magpie_bin || -L $magpie_bin ]]; then
        [[ -f $magpie_bin && -x $magpie_bin && ! -L $magpie_bin ]] || fail magpie_existing_path_not_executable
        _bootstrap_hash "$magpie_bin" "$(_bootstrap_magpie_hash)" || fail pinned_magpie_mismatch
    fi
    _bootstrap_ask_path config_home 'Absolute native XDG config home (PARENT of magpie, not plugin directory)' "${config_home:-${XDG_CONFIG_HOME:-$HOME/.config}}"
    _bootstrap_prepare_directory "$config_home"
    plugin_path=$(_bootstrap_plugin_path)
    _bootstrap_confirm "Use native plugin location $plugin_path (derived, not separately configurable)?"
    _bootstrap_ask_path bun_path 'Pinned Bun 1.4.4 executable (download if missing)' "${bun_path:-${XDG_CACHE_HOME:-$HOME/.cache}/magpie/bun/1.4.4/magpie-bun}"
    _bootstrap_ask_path host_path 'Pinned host-25ef7cf0d281.js (download if missing)' "${host_path:-${XDG_CACHE_HOME:-$HOME/.cache}/magpie/plugin-host/host-25ef7cf0d281.js}"
    _bootstrap_install_runtimes "$work"
    if [[ -e $magpie_bin || -L $magpie_bin ]]; then
        [[ -f $magpie_bin && -x $magpie_bin && ! -L $magpie_bin ]] || fail magpie_existing_path_not_executable
    else
        _bootstrap_download_magpie "$magpie_bin" "$work"
    fi
    _bootstrap_hash "$magpie_bin" "$(_bootstrap_magpie_hash)" || fail pinned_magpie_mismatch
    if [[ ! -e $plugin_path && ! -L $plugin_path ]]; then _bootstrap_install_plugin "$work"; fi
    _bootstrap_check_paths
    _bootstrap_confirm 'Persist these installation paths for future onboarding commands?'
    config_new=$work/install.json
    jq -n --arg magpie_bin "$magpie_bin" --arg config_home "$config_home" --arg plugin_path "$plugin_path" \
        --arg bun_path "$bun_path" --arg host_path "$host_path" \
        '{magpie_bin:$magpie_bin,config_home:$config_home,plugin_path:$plugin_path,bun_path:$bun_path,host_path:$host_path}' > "$config_new" || fail install_config_write_failed
    chmod 600 "$config_new" && sync -f "$config_new" && mv -fT -- "$config_new" "$TMP/shell-install.json" && sync -f "$TMP" || fail install_config_write_failed
    emit bootstrap_complete
)
