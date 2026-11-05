#!/usr/bin/env bash
# Shared private state and bounded HTTP helpers. Never source user configuration.
BASE=https://console.enterprise.trae.cn
MAIL_BASE=https://www.nimail.cn
STATE_READY=0
HTTP_CODE= HTTP_ERROR= HTTP_BODY=

emit() {
    local event=$1 payload=${2:-'{}'}
    jq -cn --arg event "$event" --argjson payload "$payload" '$payload + {event:$event}'
}
fail() {
    local reason=$1
    if ! command -v jq >/dev/null 2>&1; then
        case $reason in *[!a-zA-Z0-9_]*|'') reason=bootstrap_failed;; esac
        printf '{"event":"stopped","reason":"%s"}\n' "$reason" >&2
        exit 1
    fi
    if [[ ${STATE_READY:-0} == 1 && -f ${STATE_FILE:-} ]]; then
        jq --arg reason "$reason" '.status="PAUSED" | .reason=$reason | if .model_publication.status=="PENDING" then .model_publication.status="FAILED" else . end | if .gateway.status=="PENDING" then .gateway.status="FAILED" else . end' "$STATE_FILE" > "$RUN_DIR/failure.json" &&
            mv "$RUN_DIR/failure.json" "$STATE_FILE" && state_save || true
    fi
    emit stopped "$(jq -cn --arg reason "$reason" '{reason:$reason}')" >&2
    exit 1
}
random_hex() { od -An -N "${1:-16}" -tx1 /dev/urandom | tr -d ' \n'; }
now() { date +%s; }
private_dir() {
    local path=$1
    [[ ! -L $path ]] || fail unsafe_directory
    mkdir -p -m 700 -- "$path" || fail directory_creation_failed
    [[ $(realpath -e -- "$path") == "$path" && $(stat -c %u -- "$path") == "$UID" ]] || fail unsafe_directory
    [[ $((8#$(stat -c %a -- "$path") & 077)) == 0 ]] || fail insecure_directory_permissions
}
state_open() {
    mkdir -p -m 700 -- "$TMP"
    [[ ! -L $TMP && $(realpath -e "$TMP") == "$TMP" ]] || fail unsafe_tmp
    local lexical
    lexical=$(realpath -s -m -- "$STATE_DIR")
    STATE_DIR=$(realpath -m -- "$STATE_DIR")
    [[ $STATE_DIR == "$TMP/"* && $lexical == "$STATE_DIR" ]] || fail state_must_be_inside_project_tmp
    private_dir "$STATE_DIR"
    [[ ! -L $TMP/bash-onboarding.lock ]] || fail unsafe_lock
    exec {STATE_LOCK}>"$TMP/bash-onboarding.lock"
    flock -n "$STATE_LOCK" || fail another_onboarding_run_is_active
    private_dir "$STATE_DIR/keys"
    private_dir "$STATE_DIR/gpg"
    RUN_DIR=$(mktemp -d "$TMP/bash-run.XXXXXXXX") || fail temporary_directory_failed
    STATE_FILE=$RUN_DIR/state.json
    STATE_KEY=$STATE_DIR/keys/state.key
    [[ ! -L $STATE_KEY && ! -L $STATE_DIR/state.gpg ]] || fail state_symlink_not_allowed
    if [[ ! -e $STATE_KEY ]]; then
        [[ ! -e $STATE_DIR/state.gpg ]] || fail encrypted_state_key_missing
        random_hex 32 > "$STATE_KEY"
        chmod 600 "$STATE_KEY"
        sync -f "$STATE_KEY"
    fi
    [[ $(stat -c %u "$STATE_KEY") == "$UID" && $((8#$(stat -c %a "$STATE_KEY") & 077)) == 0 ]] || fail insecure_key_permissions
    if [[ -f $STATE_DIR/state.gpg ]]; then
        timeout 35 gpg --homedir "$STATE_DIR/gpg" --batch --no-options --pinentry-mode loopback \
            --passphrase-file "$STATE_KEY" --output "$STATE_FILE" --decrypt "$STATE_DIR/state.gpg" 2>"$RUN_DIR/gpg.error" || fail encrypted_storage_failed
        jq -e '.version == 2 and .engine == "bash" and (.members|type=="array")' "$STATE_FILE" >/dev/null || fail unsupported_state_version
    else
        printf '%s\n' '{"version":2,"engine":"bash","status":"READY","members":[],"tenant_id":null}' > "$STATE_FILE"
    fi
    STATE_READY=1
}
state_save() {
    local encrypted
    encrypted=$(mktemp "$STATE_DIR/.state.XXXXXXXX") || return 1
    if ! timeout 35 gpg --homedir "$STATE_DIR/gpg" --batch --yes --no-options --pinentry-mode loopback \
        --passphrase-file "$STATE_KEY" --cipher-algo AES256 --output "$encrypted" --symmetric "$STATE_FILE" 2>"$RUN_DIR/gpg.error"; then
        rm -f -- "$encrypted"; return 1
    fi
    sync -f "$encrypted" && mv -f -- "$encrypted" "$STATE_DIR/state.gpg" && sync -f "$STATE_DIR"
}
state_update() {
    local filter=$1; shift
    jq "$@" "$filter" "$STATE_FILE" > "$RUN_DIR/state.next" || fail state_update_failed
    mv "$RUN_DIR/state.next" "$STATE_FILE"
    state_save || fail encrypted_storage_failed
}
task_mark() {
    local phase=$1 extra=${2:-'{}'}
    state_update '.members[$i] += $extra | .members[$i].phase=$phase' \
        --argjson i "$TASK_INDEX" --arg phase "$phase" --argjson extra "$extra"
    emit member_progress "$(jq -cn --arg phase "$phase" --argjson index "$TASK_INDEX" '{phase:$phase,index:$index}')"
}
cleanup() {
    local rc=$?
    trap - EXIT INT TERM ERR
    if declare -F native_cleanup >/dev/null; then native_cleanup || true; fi
    if [[ ${STATE_READY:-0} == 1 && $rc != 0 && -f ${STATE_FILE:-} ]]; then
        jq '.status="PAUSED"' "$STATE_FILE" > "$RUN_DIR/exit.json" && mv "$RUN_DIR/exit.json" "$STATE_FILE" && state_save || true
    fi
    if [[ -n ${RUN_DIR:-} && $RUN_DIR == "$TMP/bash-run."* && -d $RUN_DIR && ! -L $RUN_DIR ]]; then rm -rf -- "$RUN_DIR"; fi
    exit "$rc"
}

# curl: result always in a private file; no secret body/URL in argv or logs.
http_probe() {
    local base=$1 code
    code=$(timeout 16 curl -q -4 -sS --connect-timeout 5 --max-time 12 --output /dev/null --write-out '%{http_code}' "$base/" 2>/dev/null) || return 1
    [[ $code =~ ^(200|301|302|307|308|404)$ ]]
}
http_request() {
    local base=$1 path=$2 jar=$3 payload=$4 safe=${5:-0} format=${6:-json} raw=${7:-0}
    local attempt count=1 rc=0
    HTTP_BODY=$RUN_DIR/http.body HTTP_ERROR=
    [[ $safe == 1 ]] && count=2
    [[ $base == "$BASE" || $base == "$MAIL_BASE" ]] || fail invalid_http_origin
    [[ $path == /* && $path != *$'\n'* && $path != *$'\r'* && $path != *'"'* && $path != *'\\'* ]] || fail invalid_http_path
    printf 'url = "%s%s"\n' "$base" "$path" > "$RUN_DIR/http.conf"
    local referer="$base/"
    if [[ $jar == "$RUN_DIR/member.cookies" && -f $RUN_DIR/member.referer ]]; then
        referer=$(<"$RUN_DIR/member.referer")
        [[ $referer == "$BASE/authorization?"* && $referer != *$'\n'* && $referer != *'"'* && $referer != *'\\'* ]] || fail invalid_referer
    fi
    printf 'header = "Referer: %s"\n' "$referer" >> "$RUN_DIR/http.conf"
    local args=(-q -4 -sS --connect-timeout 8 --max-time 25 --max-filesize 8000000 --proto '=https'
        --cookie "$jar" --cookie-jar "$jar" --header 'Accept: application/json'
        --header "Origin: $base" --output "$HTTP_BODY" --write-out '%{http_code}'
        --config "$RUN_DIR/http.conf")
    if [[ $payload != - ]]; then
        if [[ $format == json ]]; then args+=(--header 'Content-Type: application/json' --data-binary "@$payload")
        else args+=(--header 'Content-Type: application/x-www-form-urlencoded' --data-binary "@$payload"); fi
    fi
    for ((attempt=1;attempt<=count;attempt++)); do
        rc=0
        HTTP_CODE=$(timeout 30 curl "${args[@]}" 2>"$RUN_DIR/http.error") || rc=$?
        if ((rc != 0)) || [[ $HTTP_CODE =~ ^50[234]$ ]]; then
            if ((attempt < count)) && http_probe "$base"; then continue; fi
            if [[ $safe == 1 ]]; then HTTP_ERROR=network_unavailable; else HTTP_ERROR=request_outcome_unknown; fi
            return 1
        fi
        [[ $HTTP_CODE == 200 ]] || { HTTP_ERROR=upstream_http_failure; return 1; }
        [[ $raw == 1 ]] && return 0
        jq -e 'type=="object"' "$HTTP_BODY" >/dev/null 2>&1 || { HTTP_ERROR=invalid_response_shape; return 1; }
        if [[ $base == "$BASE" ]]; then
            jq -e '.code == 0 and (.code|type=="number")' "$HTTP_BODY" >/dev/null || { HTTP_ERROR=upstream_business_failure; return 1; }
        else
            jq -e '.success == true or .success == "true"' "$HTTP_BODY" >/dev/null || { HTTP_ERROR=mail_api_rejected; return 1; }
        fi
        return 0
    done
    return 1
}

admin_load() {
    local line key value first last
    local account=${TRAE_ADMIN_ACCOUNT:-} password=${TRAE_ADMIN_PASSWORD:-}
    if [[ -f $ENV_FILE ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            line=${line%$'\r'}
            [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?(TRAE_ADMIN_ACCOUNT|TRAE_ADMIN_PASSWORD)=(.*)$ ]] || continue
            key=${BASH_REMATCH[2]} value=${BASH_REMATCH[3]}
            first=${value:0:1} last=${value: -1}
            if [[ $first == "'" || $first == '"' ]]; then
                [[ ${#value} -ge 2 && $last == "$first" ]] || fail invalid_admin_setting
                value=${value:1:${#value}-2}
            else
                [[ $value != *[[:space:]]* && $value != *'#'* ]] || fail admin_value_requires_quotes
            fi
            [[ -n $value ]] || fail missing_admin_setting
            if [[ $key == TRAE_ADMIN_ACCOUNT && -z $account ]]; then account=$value; fi
            if [[ $key == TRAE_ADMIN_PASSWORD && -z $password ]]; then password=$value; fi
        done < "$ENV_FILE"
    fi
    [[ -n $account && -n $password && $password != REPLACE_WITH_ADMIN_PASSWORD ]] || fail missing_admin_setting
    # jq reads strings from private files instead of exposing passwords as args.
    printf %s "$account" > "$RUN_DIR/admin.email"
    printf %s "$password" > "$RUN_DIR/admin.password"
    jq -n --rawfile email "$RUN_DIR/admin.email" --rawfile password "$RUN_DIR/admin.password" \
        '{Email:$email,Password:$password}' > "$RUN_DIR/admin.credentials"
}
enterprise_login() {
    local identity=$1
    rm -f -- "$RUN_DIR/$identity.cookies"
    http_request "$BASE" /trae/gtm/tob/api/v1/account/login "$RUN_DIR/$identity.cookies" "$RUN_DIR/$identity.credentials" 0 || fail "$HTTP_ERROR"
    jq -e '.Data.IsAllowLogin==true' "$HTTP_BODY" >/dev/null && grep -q 'X-Cloudide-Tob-Session' "$RUN_DIR/$identity.cookies" || fail login_not_confirmed
}
enterprise_read() {
    local identity=$1 path=$2 payload=$3
    [[ -f $RUN_DIR/$identity.cookies ]] || enterprise_login "$identity"
    if ! http_request "$BASE" "$path" "$RUN_DIR/$identity.cookies" "$payload" 1; then
        if [[ $HTTP_ERROR == upstream_business_failure ]] && jq -e '.code==30011' "$HTTP_BODY" >/dev/null; then
            enterprise_login "$identity"
            http_request "$BASE" "$path" "$RUN_DIR/$identity.cookies" "$payload" 1 || fail "$HTTP_ERROR"
        else fail "$HTTP_ERROR"; fi
    fi
}
