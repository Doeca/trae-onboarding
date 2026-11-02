#!/usr/bin/env bash
# Original native host/plugin only; the launcher preloads the reviewed fetch guard.
NATIVE_PID= NATIVE_INPUT= NATIVE_RESULT=

native_hash() {
    [[ -f $1 && ! -L $1 ]] || fail native_asset_missing
    local sum
    sum=$(sha256sum -- "$1") || fail native_asset_unreadable
    [[ ${sum%% *} == "$2" ]] || fail native_runtime_integrity_failed
}
native_auth_read() {
    local target=$1 auth=$CONFIG_HOME/magpie/plugin-auth.json
    [[ ! -L $auth ]] || fail native_auth_unsafe
    if [[ ! -e $auth ]]; then printf '{}\n' > "$target"; return; fi
    [[ -f $auth && $(stat -c %s "$auth") -le 8000000 && $(realpath -e "$auth") == "$auth" ]] || fail native_auth_unsafe
    jq -e 'type=="object"' "$auth" >/dev/null 2>&1 || fail native_auth_unreadable
    cp -- "$auth" "$target" || fail native_auth_unreadable
    chmod 600 "$target"
}
native_preflight() {
    umask 077
    LOGIN_TIMEOUT=${LOGIN_TIMEOUT:-120}
    [[ $LOGIN_TIMEOUT =~ ^[0-9]+$ ]] && (( LOGIN_TIMEOUT > 0 && LOGIN_TIMEOUT <= 3600 )) || fail native_timeout_invalid
    [[ $CONFIG_HOME == /* && $(realpath -e "$CONFIG_HOME") == "$CONFIG_HOME" && -d $CONFIG_HOME/magpie && ! -L $CONFIG_HOME/magpie ]] || fail native_config_unsafe
    [[ $RUN_DIR == "$TMP/"* && $(realpath -e "$RUN_DIR") == "$RUN_DIR" && $(stat -c %u "$RUN_DIR") == "$UID" && $((8#$(stat -c %a "$RUN_DIR") & 077)) == 0 ]] || fail native_work_unsafe
    [[ -d $PLUGIN_PATH ]] && PLUGIN_PATH=$PLUGIN_PATH/index.mjs
    native_hash "$MAGPIE_BIN" f730747a84cc3932da6f6a84926cf428a10ee2224c5c6dfbf37df9dbfd4dffb6
    native_hash "$BUN_PATH" 10702245766b225e70bbf6235fd6b47214fd94b4760d00ffaed8ab0df57ac235
    native_hash "$HOST_PATH" 25ef7cf0d2813cc25a2e3675c28b5fa9ce9ec87f1b5a621803a193ab3929dbac
    native_hash "$PLUGIN_PATH" df2eb4515bd4dd3a863006023385038a8c79eb09d1efe849fd14af979b810d1d
    native_hash "$PROJECT/onboarding/network_guard.mjs" 9a43427222c1d38ce300aba5fd6b79fb0af4b4478690d3341463c141b833ee2f
    [[ -x $MAGPIE_BIN && -x $BUN_PATH && ! -L $CONFIG_HOME/magpie/plugins.json ]] || fail native_command_unavailable
    jq -e '.plugins | type=="array" and any(.[]; (.spec // "" | contains("opencode-trae-auth")))' "$CONFIG_HOME/magpie/plugins.json" >/dev/null 2>&1 || fail native_trae_plugin_not_registered
    # Registry package resolution must select the pinned installed implementation.
    local installed=$CONFIG_HOME/magpie/plugins/node_modules/@magpie-community/opencode-trae-auth/index.mjs
    [[ $(realpath -e "$installed") == "$(realpath -e "$PLUGIN_PATH")" ]] || fail native_plugin_selection_unverified
    native_auth_read "$RUN_DIR/native.preflight-auth"
    mkdir -m 700 -p "$RUN_DIR/native-bin" "$RUN_DIR/native-cache/magpie/plugin-host" "$RUN_DIR/native-data"
    cp -- "$HOST_PATH" "$RUN_DIR/native-cache/magpie/plugin-host/host-25ef7cf0d281.js"
    native_hash "$RUN_DIR/native-cache/magpie/plugin-host/host-25ef7cf0d281.js" 25ef7cf0d2813cc25a2e3675c28b5fa9ce9ec87f1b5a621803a193ab3929dbac
    local name
    for name in xdg-open gio sensible-browser x-www-browser open firefox chromium chromium-browser google-chrome; do
        printf '#!/bin/sh\nexit 0\n' > "$RUN_DIR/native-bin/$name"
        chmod 700 "$RUN_DIR/native-bin/$name"
    done
    {
        printf '#!/bin/bash\n'
        printf 'if [[ ${1:-} == run ]]; then shift; exec %q run --preload %q "$@"; fi\n' "$BUN_PATH" "$PROJECT/onboarding/network_guard.mjs"
        printf 'if [[ ${1:-} == --version ]]; then exec %q --version; fi\nexit 64\n' "$BUN_PATH"
    } > "$RUN_DIR/native-bin/guarded-bun"
    chmod 700 "$RUN_DIR/native-bin/guarded-bun"
}
native_environment() {
    local name
    NATIVE_ENV=(env -i)
    while IFS= read -r name; do
        case $name in LANG|LC_ALL|LC_CTYPE|LARKSUITE_CLI_CONFIG_DIR|LARK_CHANNEL*) NATIVE_ENV+=("$name=${!name}");; esac
    done < <(compgen -e)
    NATIVE_NONCE=$(od -An -N 24 -tx1 /dev/urandom | tr -d ' \n')
    rm -f -- "$RUN_DIR/guard-loaded"
    NATIVE_ENV+=("HOME=$HOME" "XDG_CONFIG_HOME=$CONFIG_HOME" "XDG_CACHE_HOME=$RUN_DIR/native-cache"
        "XDG_DATA_HOME=$RUN_DIR/native-data" "MAGPIE_BUN=$RUN_DIR/native-bin/guarded-bun"
        "PATH=$RUN_DIR/native-bin:/usr/local/bin:/usr/bin:/bin" "BROWSER=$RUN_DIR/native-bin/xdg-open"
        'DISPLAY=' 'WAYLAND_DISPLAY=' 'BUN_OPTIONS=' 'NODE_OPTIONS=' 'NO_COLOR=1' 'TERM=dumb'
        "NATIVE_MAGPIE_GUARD_MARKER=$RUN_DIR/guard-loaded" "NATIVE_MAGPIE_GUARD_NONCE=$NATIVE_NONCE")
}
native_cleanup() {
    if [[ -n ${NATIVE_PID:-} ]]; then
        kill -TERM -- "-$NATIVE_PID" 2>/dev/null || true
        local n
        for ((n=0;n<20;n++)); do kill -0 -- "-$NATIVE_PID" 2>/dev/null || break; sleep .1; done
        kill -KILL -- "-$NATIVE_PID" 2>/dev/null || true
        wait "$NATIVE_PID" 2>/dev/null || true
        NATIVE_PID=
    fi
    if [[ -n ${NATIVE_INPUT:-} ]]; then exec {NATIVE_INPUT}>&-; NATIVE_INPUT=; fi
}
native_start() {
    [[ -z ${NATIVE_PID:-} ]] || fail native_login_busy
    local purpose=$1; shift
    native_environment
    [[ $purpose != login ]] || NATIVE_ENV+=('MAGPIE_NO_ACCOUNTS=1')
    [[ $purpose != web ]] || NATIVE_ENV+=("MAGPIE_WEB_KEY=$MODEL_WEB_KEY")
    rm -f -- "$RUN_DIR/native.stdin"
    mkfifo -m 600 "$RUN_DIR/native.stdin" || fail native_fifo_failed
    exec {NATIVE_INPUT}<>"$RUN_DIR/native.stdin"
    # Limit both lifetime and disk output, including a child whose parent exited.
    (
        cd "$RUN_DIR"
        local env_name
        # Bash builtins set child-only env: web key never appears in env(1) argv.
        while IFS= read -r env_name; do unset "$env_name" 2>/dev/null || true; done < <(compgen -e)
        export "${NATIVE_ENV[@]:2}"
        ulimit -f 4096
        exec setsid timeout --foreground --signal=TERM --kill-after=2 "${LOGIN_TIMEOUT:-120}" "$MAGPIE_BIN" "$@" < "$RUN_DIR/native.stdin" > "$RUN_DIR/native.output" 2>&1
    ) &
    NATIVE_PID=$!
    NATIVE_DEADLINE=$((SECONDS + LOGIN_TIMEOUT))
}
native_guard_confirm() {
    [[ -f $RUN_DIR/guard-loaded && ! -L $RUN_DIR/guard-loaded && $(<"$RUN_DIR/guard-loaded") == "$NATIVE_NONCE" ]] || fail native_guard_not_loaded
}
native_output_check() {
    (( SECONDS < NATIVE_DEADLINE )) || fail native_login_timeout
    [[ ! -f $RUN_DIR/native.output || $(stat -c %s "$RUN_DIR/native.output") -le 2000000 ]] || fail native_output_limit
}
native_query() {
    jq -eRs -f "$PROJECT/shell/query.jq" "$1" > "$2" 2>/dev/null
}
native_matches() {
    jq --slurpfile pair "$2" '[to_entries[] | select((.key=="trae-cn" or (.key|startswith("trae-cn#"))) and (.value|type=="object") and .value.type=="oauth" and .value.access==$pair[0].Token and .value.refresh==$pair[0].RefreshToken)]' "$1" > "$3" || fail native_auth_unreadable
}
native_result() {
    NATIVE_RESULT=$(jq -c '.[0] | {account_key:.key, uid_present:((.value.uid // "" | tostring | length)>0), tenant_present:((.value.account.TenantID // "" | tostring | length)>0),guarded:true,storage:"selected"}' "$1") || fail native_auth_unreadable
}
native_reconcile() {
    NATIVE_RESULT=
    jq -e --argjson i "$TASK_INDEX" '.members[$i].credentials!=null' "$STATE_FILE" >/dev/null || return 1
    jq -e --argjson i "$TASK_INDEX" '.members[$i].credentials | select(type=="object" and (.Token|type=="string" and length>0) and (.RefreshToken|type=="string" and length>0))' "$STATE_FILE" > "$RUN_DIR/native.pair" || fail native_credentials_invalid
    native_auth_read "$RUN_DIR/native.auth"
    native_matches "$RUN_DIR/native.auth" "$RUN_DIR/native.pair" "$RUN_DIR/native.matches"
    case $(jq length "$RUN_DIR/native.matches") in
        0) NATIVE_RESULT=; return 1;;
        1) native_result "$RUN_DIR/native.matches";;
        *) fail native_auth_ambiguous;;
    esac
}
native_payload() {
    jq -en --slurpfile q "$1" --slurpfile issued "$2" '
      $issued[0] as $i | $i.credentials as $c | $i.initial_refresh as $r | $i.identity.HostInfo as $h | $i.identity.Data as $d |
      if ([$c.Token,$c.RefreshToken,$r.RefreshToken,$d.UserInfo.Scope] | all(.[]; type=="string" and length>0))
         and ($r.RefreshExpireAt|type=="number")
         and ([$h.Api,$h.Console,$h.Core]|all(.[]; .=="https://console.enterprise.trae.cn")) then
      {scope:$d.UserInfo.Scope,host:$h.Api,consoleHost:$h.Console,coreHost:$h.Core,isRedirect:"true",
       loginTraceID:$q[0].login_trace_id[0],userJwt:($c|tojson),userInfo:($d|tojson),refreshToken:$r.RefreshToken,
       refreshExpireAt:($r.RefreshExpireAt|tostring),data:$r.RefreshToken,
       datafinderConfig:($h.DataFinderConfig // {}|tojson),apmPlusConfig:($h.ApmPlusConfig // {}|tojson)}
      else error("invalid") end' > "$3" 2>/dev/null || fail native_callback_payload_invalid
}
native_callback_config() {
    jq -nr --slurpfile query "$1" --slurpfile payload "$2" '
      ($payload[0]|to_entries|map((.key|@uri)+"="+(.value|tostring|@uri))|join("&")) as $args |
      "url = " + (($query[0].auth_callback_url[0]+"?"+$args)|tojson)' > "$3"
}
native_login() {
    native_auth_read "$RUN_DIR/native.before"
    native_start login plugin login trae-cn
    while :; do
        native_output_check
        if [[ -f $RUN_DIR/native.output ]] && native_query "$RUN_DIR/native.output" "$RUN_DIR/native.query"; then break; fi
        kill -0 "$NATIVE_PID" 2>/dev/null || fail native_login_url_missing
        sleep .1
    done
    native_guard_confirm
    # Keep the validated URL immutable even if the service changes its input file.
    cp "$RUN_DIR/native.query" "$RUN_DIR/issue.query"
    issue_tokens "$RUN_DIR/issue.query" "$RUN_DIR/native.issued"
    native_output_check
    native_payload "$RUN_DIR/native.query" "$RUN_DIR/native.issued" "$RUN_DIR/native.payload"
    jq '.credentials' "$RUN_DIR/native.issued" > "$RUN_DIR/native.pair"
    native_matches "$RUN_DIR/native.before" "$RUN_DIR/native.pair" "$RUN_DIR/native.matches"
    [[ $(jq length "$RUN_DIR/native.matches") == 0 ]] || fail native_credentials_preexisting
    native_callback_config "$RUN_DIR/native.query" "$RUN_DIR/native.payload" "$RUN_DIR/native.callback"
    local code remaining=$((NATIVE_DEADLINE - SECONDS))
    (( remaining > 15 )) && remaining=15
    code=$(timeout "$((remaining+1))" curl -q -4 -sS --noproxy '*' --proto '=http' --connect-timeout 3 --max-time "$remaining" --max-filesize 1000000 --config "$RUN_DIR/native.callback" --output /dev/null --write-out '%{http_code}' 2> "$RUN_DIR/native.curl-error") || fail native_callback_http_failed
    [[ $code == 200 ]] || fail native_callback_http_failed
    while kill -0 "$NATIVE_PID" 2>/dev/null; do native_output_check; sleep .1; done
    wait "$NATIVE_PID" || fail native_cli_failed
    native_output_check
    native_auth_read "$RUN_DIR/native.after"
    native_matches "$RUN_DIR/native.after" "$RUN_DIR/native.pair" "$RUN_DIR/native.matches"
    [[ $(jq length "$RUN_DIR/native.matches") == 1 ]] || fail native_auth_not_saved_or_ambiguous
    # Preserve every old account, including other trae-cn accounts, except the one written.
    jq -e --slurpfile before "$RUN_DIR/native.before" --slurpfile matches "$RUN_DIR/native.matches" '
      . as $after | all($before[0]|to_entries[]; .key==$matches[0][0].key or $after[.key]==.value)' "$RUN_DIR/native.after" >/dev/null || fail native_unrelated_accounts_changed
    native_result "$RUN_DIR/native.matches"
    NATIVE_RESULT=$(jq -cn --argjson result "$NATIVE_RESULT" --slurpfile matches "$RUN_DIR/native.matches" --slurpfile issued "$RUN_DIR/native.issued" '
      $matches[0][0].value as $auth | $issued[0].identity.Data.UserInfo as $expected |
      $result + {uid_matches:($result.uid_present and (($auth.uid|tostring)==($expected.UserID|tostring))),
                 tenant_matches:($result.tenant_present and (($auth.account.TenantID|tostring)==($expected.TenantID|tostring)))}')
    native_cleanup
}
