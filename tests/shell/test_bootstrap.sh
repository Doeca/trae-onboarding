#!/usr/bin/env bash
# Offline synthetic tests; only writes below this repository's tmp directory.
set -euo pipefail
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
mkdir -p -m 700 "$REPO/tmp"
SUITE=$(mktemp -d "$REPO/tmp/bootstrap-tests.XXXXXXXX")
trap 'rm -rf -- "$SUITE"' EXIT
REAL_SHA=$(command -v sha256sum)
source "$REPO/shell/bootstrap.sh"
fail() { printf 'FAIL:%s\n' "$1" >&2; exit 1; }
emit() { printf 'EVENT:%s\n' "$1"; }
fixture() {
    PROJECT=$(mktemp -d "$SUITE/case.XXXXXXXX") TMP=''
    TMP=$PROJECT/tmp
    mkdir -p -m 700 "$TMP" "$PROJECT/config/magpie/plugins/node_modules/@magpie-community/opencode-trae-auth" "$PROJECT/bin"
    magpie_bin=$PROJECT/bin/magpie config_home=$PROJECT/config
    plugin_path=$(_bootstrap_plugin_path) bun_path=$PROJECT/bin/bun host_path=$PROJECT/host.js
    printf '#!/bin/sh\nexit 0\n' > "$magpie_bin"
    printf 'synthetic-bun\n' > "$bun_path"
    printf 'synthetic-host\n' > "$host_path"
    printf 'export default {};\n' > "$plugin_path"
    printf '%s\n' '{"name":"@magpie-community/opencode-trae-auth","version":"0.2.26","main":"./index.mjs"}' > "${plugin_path%/*}/package.json"
    chmod 700 "$magpie_bin" "$bun_path"
    save_fixture
}
save_fixture() {
    jq -n --arg magpie_bin "$magpie_bin" --arg config_home "$config_home" --arg plugin_path "$plugin_path" --arg bun_path "$bun_path" --arg host_path "$host_path" \
        '{magpie_bin:$magpie_bin,config_home:$config_home,plugin_path:$plugin_path,bun_path:$bun_path,host_path:$host_path}' > "$TMP/shell-install.json"
    chmod 600 "$TMP/shell-install.json"
}
# SHA command double authenticates only synthetic content, never real runtime.
fake_runtime_hashes() {
    timeout() { [[ $1 != --kill-after=* ]] || shift; shift; "$@"; }
    sha256sum() {
        local file=${@: -1} content
        content=$(<"$file")
        if [[ $file == "$magpie_bin" ]]; then printf '%s  %s\n' "$(_bootstrap_magpie_hash)" "$file"; return; fi
        if [[ $file == "$plugin_path" ]]; then printf '%s  %s\n' "$(_bootstrap_plugin_hash)" "$file"; return; fi
        case $content in
            synthetic-bun) printf '%s  %s\n' "$(_bootstrap_bun_hash)" "$file" ;;
            synthetic-host) printf '%s  %s\n' "$(_bootstrap_host_hash)" "$file" ;;
            *) "$REAL_SHA" "$@" ;;
        esac
    }
}
expect_failure() {
    local expected=$1; shift
    local output rc=0
    output=$("$@" 2>&1) || rc=$?
    [[ $rc != 0 && $output == *"FAIL:$expected"* ]] || { printf 'Wrong failure: %s\n' "$output" >&2; return 1; }
    [[ $output != *"$PROJECT"* ]]
}
mock_terminal() {
    # Only tests replace terminal IO; production never supports input-file flags.
    unset LARK_CHANNEL LARK_CHANNEL_CHAT_ID LARKSUITE_CLI_CONFIG_DIR
    _bootstrap_open_tty() { exec {BOOTSTRAP_TTY}>/dev/null; }
    _bootstrap_ask_path() { _bootstrap_absolute "${!1}"; }
    _bootstrap_confirm() { :; }
}
case_load() {
    fixture
    load_install_config
    [[ $MAGPIE_BIN == "$magpie_bin" && $CONFIG_HOME == "$config_home" && $PLUGIN_PATH == "$plugin_path" && $BUN_PATH == "$bun_path" && $HOST_PATH == "$host_path" ]]
    [[ $(env | grep -c '^magpie_bin=') == 1 ]]
}
case_preflight() {
    fixture; fake_runtime_hashes
    [[ $(environment_check) == EVENT:environment_ready ]]
}
case_bad_hash() {
    fixture
    expect_failure pinned_magpie_mismatch environment_check
}
case_real_hash() {
    fixture
    local hash
    hash=$("$REAL_SHA" "$host_path"); hash=${hash%% *}
    _bootstrap_hash "$host_path" "$hash"
    ! _bootstrap_hash "$host_path" "$(_bootstrap_host_hash)"
    mv "$host_path" "$host_path.real"; ln -s "$host_path.real" "$host_path"
    ! _bootstrap_hash "$host_path" "$hash"
}
case_config_permissions() {
    fixture; chmod 644 "$TMP/shell-install.json"
    expect_failure install_config_missing_or_insecure load_install_config
}
case_config_symlink() {
    fixture; mv "$TMP/shell-install.json" "$TMP/real.json"; ln -s real.json "$TMP/shell-install.json"
    expect_failure install_config_missing_or_insecure load_install_config
}
case_tmp_permissions() {
    fixture; chmod 755 "$TMP"
    expect_failure insecure_install_tmp_permissions load_install_config
}
case_config_injection() {
    fixture
    jq --arg value '/$(touch PWNED)' '.magpie_bin=$value' "$TMP/shell-install.json" > "$TMP/new.json"
    mv "$TMP/new.json" "$TMP/shell-install.json"; chmod 600 "$TMP/shell-install.json"
    load_install_config
    [[ $MAGPIE_BIN == '/$(touch PWNED)' && ! -e $PROJECT/PWNED ]]
    expect_failure magpie_executable_missing _bootstrap_check_paths
}
case_control_json() {
    fixture
    jq '.magpie_bin="/bad\u0000value"' "$TMP/shell-install.json" > "$TMP/new.json"
    mv "$TMP/new.json" "$TMP/shell-install.json"; chmod 600 "$TMP/shell-install.json"
    expect_failure invalid_install_config load_install_config
}
case_wrong_plugin_path() {
    fixture; plugin_path=$PROJECT/index.mjs; save_fixture
    expect_failure plugin_path_not_native_config load_install_config
}
case_plugin_version() {
    fixture; fake_runtime_hashes
    printf '%s\n' '{"name":"@magpie-community/opencode-trae-auth","version":"latest","main":"index.mjs"}' > "${plugin_path%/*}/package.json"
    expect_failure native_trae_package_pin_mismatch environment_check
}
case_bridge() {
    fixture
    export LARK_CHANNEL_CHAT_ID=''
    expect_failure bootstrap_requires_local_terminal_not_bridge bootstrap_interactive
    [[ ! -e $TMP/shell-bootstrap.lock ]]
}
case_no_terminal() {
    fixture
    local output rc=0
    output=$(setsid --wait bash -c '
        source "$1"; PROJECT=$2; TMP=$PROJECT/tmp
        fail() { printf "FAIL:%s\n" "$1" >&2; exit 1; }
        emit() { :; }
        bootstrap_interactive
    ' _ "$REPO/shell/bootstrap.sh" "$PROJECT" </dev/null 2>&1) || rc=$?
    [[ $rc != 0 && $output == *FAIL:bootstrap_requires_local_terminal* && $output != *"$PROJECT"* ]]
}
case_consent_declined() {
    fixture
    _bootstrap_ask() { printf -v "$1" no; }
    expect_failure bootstrap_consent_declined _bootstrap_confirm 'synthetic consent'
}
case_default_magpie() {
    fixture
    unset magpie_bin MAGPIE_BIN_DIR
    local HOME=$PROJECT/home
    type() { return 1; }
    [[ $(_bootstrap_default_magpie) == "$HOME/.local/bin/magpie" ]]
    MAGPIE_BIN_DIR=$PROJECT/custom-bin
    [[ $(_bootstrap_default_magpie) == "$MAGPIE_BIN_DIR/magpie" ]]
}
case_detected_magpie() {
    fixture
    local expected=$magpie_bin
    unset magpie_bin
    type() { printf '%s\n' "$expected"; }
    [[ $(_bootstrap_default_magpie) == "$expected" ]]
}
case_saved_magpie() {
    fixture
    type() { return 1; }
    [[ $(_bootstrap_default_magpie) == "$magpie_bin" ]]
}
mock_path_input() {
    printf '%s' "$1" > "$TMP/input"
    exec {TEST_INPUT}<"$TMP/input"
    exec {BOOTSTRAP_TTY}>"$TMP/prompts"
    # Keep real prompt/default/consent handling; split terminal input and output.
    read() { builtin read -r -u "$TEST_INPUT" "${@: -1}"; }
}
case_path_enter_default() {
    fixture
    local selected='' output
    mock_path_input $'\nYES\n'
    output=$(_bootstrap_ask_path selected 'Magpie executable' "$magpie_bin"; [[ $selected == "$magpie_bin" ]])
    [[ -z $output ]]
    [[ $(<"$TMP/prompts") == *"[$magpie_bin]"* && $(<"$TMP/prompts") == *'press Enter'* ]]
}
case_path_explicit() {
    fixture
    local selected=''
    mock_path_input "$PROJECT/other-magpie"$'\nYES\n'
    _bootstrap_ask_path selected 'Magpie executable' "$magpie_bin"
    [[ $selected == "$PROJECT/other-magpie" ]]
}
case_path_default_declined() {
    fixture
    local selected=''
    mock_path_input $'\n\n'
    expect_failure bootstrap_consent_declined _bootstrap_ask_path selected 'Magpie executable' "$magpie_bin"
}
case_path_eof() {
    fixture
    local selected=''
    mock_path_input ''
    expect_failure bootstrap_input_closed _bootstrap_ask_path selected 'Magpie executable' "$magpie_bin"
}
case_existing_bootstrap() {
    fixture; fake_runtime_hashes; mock_terminal
    local before after
    before=$("$REAL_SHA" "$magpie_bin" "$plugin_path")
    [[ $(bootstrap_interactive) == EVENT:bootstrap_complete ]]
    after=$("$REAL_SHA" "$magpie_bin" "$plugin_path")
    [[ $before == "$after" && $(stat -c %a "$TMP/shell-install.json") == 600 ]]
}
mock_download() {
    _bootstrap_confirm() { :; }
    _bootstrap_ask() {
        case $1 in
            url) printf -v "$1" '%s' "${TEST_URL:-https://artifact.invalid/magpie}" ;;
            expected) printf -v "$1" '%s' "$TEST_HASH" ;;
        esac
    }
    # Functions dispatched directly, never any real curl invocation.
    timeout() { [[ $1 != --kill-after=* ]] || shift; shift; "$@"; }
    curl() {
        local output='' arg
        while (($#)); do arg=$1; shift; if [[ $arg == --output ]]; then output=$1; shift; fi; done
        [[ $output != /dev/null ]] || { printf 200; return; }
        printf '\177ELFsynthetic-not-runnable' > "$output"
    }
    printf '\177ELFsynthetic-not-runnable' > "$PROJECT/expected"
    TEST_HASH=$("$REAL_SHA" "$PROJECT/expected"); TEST_HASH=${TEST_HASH%% *}
    # Replace reviewed manifest only within this test's shell for fake artifacts.
    TEST_MANIFEST=$TEST_HASH
    _bootstrap_magpie_hash() { printf '%s' "$TEST_MANIFEST"; }
}
case_verified_download() {
    fixture; mock_download
    mkdir -m 700 "$TMP/work"
    local destination=$PROJECT/bin/new-magpie
    [[ $(_bootstrap_download_magpie "$destination" "$TMP/work") == EVENT:magpie_installed ]]
    _bootstrap_hash "$destination" "$TEST_HASH"
    [[ $(stat -c %a "$destination") == 700 ]]
    expect_failure magpie_install_would_overwrite _bootstrap_download_magpie "$destination" "$TMP/work"
}
case_download_bad_hash() {
    fixture; mock_download
    mkdir -m 700 "$TMP/work"; TEST_HASH=$(printf '%064d' 0); TEST_MANIFEST=$TEST_HASH
    expect_failure magpie_artifact_checksum_mismatch _bootstrap_download_magpie "$PROJECT/bin/new-magpie" "$TMP/work"
    [[ ! -e $PROJECT/bin/new-magpie ]]
}
case_unsupported_manifest() {
    fixture; mock_download
    mkdir -m 700 "$TMP/work"; TEST_HASH=$(printf '%064d' 0)
    curl() { printf 'unexpected\n' > "$TMP/network-called"; return 9; }
    expect_failure unsupported_magpie_artifact_manifest _bootstrap_download_magpie "$PROJECT/bin/new-magpie" "$TMP/work"
    [[ ! -e $TMP/network-called && ! -e $PROJECT/bin/new-magpie ]]
}
case_http_rejected() {
    fixture; mock_download
    mkdir -m 700 "$TMP/work"; TEST_URL=http://artifact.invalid/magpie
    expect_failure invalid_magpie_artifact_url _bootstrap_download_magpie "$PROJECT/bin/new-magpie" "$TMP/work"
}
case_network_retry() {
    fixture; mock_download
    mkdir -m 700 "$TMP/work"
    local attempts=0 probes=0
    curl() {
        local output='' arg
        while (($#)); do arg=$1; shift; if [[ $arg == --output ]]; then output=$1; shift; fi; done
        if [[ $output == /dev/null ]]; then printf 'probe\n' >> "$TMP/probes"; printf 200; return; fi
        attempts=$((attempts + 1))
        ((attempts > 1)) || return 28
        printf '\177ELFsynthetic-not-runnable' > "$output"
    }
    _bootstrap_download_magpie "$PROJECT/bin/new-magpie" "$TMP/work" >/dev/null
    [[ $attempts == 2 && $(<"$TMP/probes") == probe ]]
}
case_permanent_no_retry() {
    fixture; mock_download
    mkdir -m 700 "$TMP/work"
    curl() { printf 'call\n' >> "$TMP/calls"; return 22; }
    expect_failure magpie_download_rejected _bootstrap_download_magpie "$PROJECT/bin/new-magpie" "$TMP/work"
    [[ $(<"$TMP/calls") == call && ! -e $PROJECT/bin/new-magpie ]]
}
case_nonelf_rejected() {
    fixture; mock_download
    mkdir -m 700 "$TMP/work"
    curl() {
        local output='' arg
        while (($#)); do arg=$1; shift; if [[ $arg == --output ]]; then output=$1; shift; fi; done
        printf '#!/bin/sh\nexit 0\n' > "$output"
    }
    TEST_HASH=$("$REAL_SHA" "$magpie_bin"); TEST_HASH=${TEST_HASH%% *}; TEST_MANIFEST=$TEST_HASH
    expect_failure magpie_artifact_must_be_linux_executable _bootstrap_download_magpie "$PROJECT/bin/new-magpie" "$TMP/work"
    [[ ! -e $PROJECT/bin/new-magpie ]]
}
case_symlink_parent() {
    fixture
    ln -s "$PROJECT/config" "$PROJECT/link-config"
    config_home=$PROJECT/link-config; plugin_path=$(_bootstrap_plugin_path); save_fixture
    expect_failure noncanonical_install_path load_install_config
}
case_native_plugin() {
    fixture; fake_runtime_hashes; mock_terminal
    rm -rf "${plugin_path%/*}"
    printf '%s\n' '#!/bin/sh' \
        'test "$1" = plugin && test "$2" = add && test "$3" = @magpie-community/opencode-trae-auth@0.2.26 || exit 9' \
        'test -f "$MAGPIE_BUN" || exit 10' \
        'dir="$XDG_CONFIG_HOME/magpie/plugins/node_modules/@magpie-community/opencode-trae-auth"' \
        'mkdir -p "$dir"' \
        'printf "export default {};\n" > "$dir/index.mjs"' \
        'printf '\''{"name":"@magpie-community/opencode-trae-auth","version":"0.2.26","main":"index.mjs"}\n'\'' > "$dir/package.json"' \
        'printf "DO_NOT_LEAK_PATHS_OR_SECRETS\n"' > "$magpie_bin"
    local output
    output=$(bootstrap_interactive)
    [[ $output == $'EVENT:native_plugin_installed\nEVENT:bootstrap_complete' && -f $plugin_path ]]
}
case_untrusted_binary_before_execution() {
    fixture; fake_runtime_hashes; mock_terminal
    rm -rf "${plugin_path%/*}"
    # Runtime files retain fake manifest hashes; binary hash explicitly fails.
    sha256sum() {
        local file=${@: -1} content
        content=$(<"$file")
        case $content in
            synthetic-bun) printf '%s  %s\n' "$(_bootstrap_bun_hash)" "$file" ;;
            synthetic-host) printf '%s  %s\n' "$(_bootstrap_host_hash)" "$file" ;;
            *) "$REAL_SHA" "$@" ;;
        esac
    }
    printf '#!/bin/sh\nprintf bad > "%s"\n' "$TMP/executed" > "$magpie_bin"
    expect_failure pinned_magpie_mismatch bootstrap_interactive
    [[ ! -e $TMP/executed ]]
}
case_missing_runtime_before_install() {
    fixture; mock_terminal
    rm "$magpie_bin"
    expect_failure pinned_bun_missing_or_mismatch bootstrap_interactive
    [[ ! -e $magpie_bin ]]
}
case_missing_dependency() {
    fixture
    command() { if [[ $* == '-v curl' ]]; then return 1; fi; builtin command "$@"; }
    expect_failure missing_dependency_curl _bootstrap_dependencies
}
case_nonlinux() {
    fixture
    uname() { printf Darwin; }
    expect_failure linux_required _bootstrap_dependencies
}
count=0
for test in load preflight bad_hash real_hash config_permissions config_symlink tmp_permissions config_injection control_json wrong_plugin_path plugin_version bridge no_terminal consent_declined default_magpie detected_magpie saved_magpie path_enter_default path_explicit path_default_declined path_eof existing_bootstrap verified_download download_bad_hash unsupported_manifest http_rejected network_retry permanent_no_retry nonelf_rejected symlink_parent native_plugin untrusted_binary_before_execution missing_runtime_before_install missing_dependency nonlinux; do
    # Invoke the subshell as a simple command, preserving errexit inside tests.
    ("case_$test")
    printf 'ok %s\n' "$test"
    count=$((count + 1))
done
printf '%s bootstrap tests passed (offline).\n' "$count"
