#!/usr/bin/env bash
# Entirely synthetic. Never execute the installed Magpie, a login, or live HTTP.
set -euo pipefail
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$PROJECT/tmp
mkdir -p "$TMP"
RUN_DIR=$(mktemp -d "$TMP/native-test.XXXXXXXX")
trap 'rm -rf -- "$RUN_DIR"' EXIT
umask 077
source "$PROJECT/shell/native.sh"
source "$PROJECT/shell/finalize.sh"
fail() { printf '%s\n' "$1" >&2; exit 1; }
emit() { :; }
state_save() { cp "$STATE_FILE" "$RUN_DIR/saved-state"; }
CONFIG_HOME=$RUN_DIR/config
mkdir -p "$CONFIG_HOME/magpie"
STATE_FILE=$RUN_DIR/state.json
TASK_INDEX=0
check_failure() {
    local expected=$1; shift
    if ( "$@" ) > "$RUN_DIR/test.stdout" 2> "$RUN_DIR/test.stderr"; then
        printf 'Expected failure: %s\n' "$expected" >&2; exit 1
    fi
    grep -qx "$expected" "$RUN_DIR/test.stderr"
}
url='https://www.trae.cn/authorization?device_id=dev%2Bid&x_device_id=dev%2Bid&login_trace_id=trace+ok&auth_callback_url=http%3A%2F%2F127.0.0.1%3A49201%2Fauthorize'
printf 'native banner\n%s\n' "$url" > "$RUN_DIR/url"
native_query "$RUN_DIR/url" "$RUN_DIR/query"
jq -e '.device_id==["dev+id"] and .login_trace_id==["trace ok"] and .auth_callback_url==["http://127.0.0.1:49201/authorize"]' "$RUN_DIR/query" >/dev/null
for bad in "${url}&device_id=duplicate" "${url/dev%2Bid/devother}" "${url/127.0.0.1/evil.example}" "${url/49201/99999}" "${url/%2Fauthorize/%2Fauthorize%3Fredirect%3Devil}" "${url}&broken=%XX"; do
    printf '%s\n' "$bad" > "$RUN_DIR/bad-url"
    if native_query "$RUN_DIR/bad-url" "$RUN_DIR/bad-query"; then fail invalid_url_accepted; fi
done
printf '%s' "$url" > "$RUN_DIR/truncated"
if native_query "$RUN_DIR/truncated" "$RUN_DIR/truncated-query"; then fail incomplete_url_accepted; fi
printf '%s\n' '{"initial_refresh":{"RefreshToken":"initial-secret","RefreshExpireAt":1800000000000},"credentials":{"Token":"access-secret","RefreshToken":"refresh-secret","TokenExpireAt":1800000000000},"identity":{"HostInfo":{"Api":"https://console.enterprise.trae.cn","Console":"https://console.enterprise.trae.cn","Core":"https://console.enterprise.trae.cn"},"Data":{"UserInfo":{"Scope":"enterprise","UserID":"001","TenantID":"002"}}}}' > "$RUN_DIR/issued"
native_payload "$RUN_DIR/query" "$RUN_DIR/issued" "$RUN_DIR/payload"
jq -e '(.userInfo|fromjson)=={UserInfo:{Scope:"enterprise",UserID:"001",TenantID:"002"}} and .refreshToken=="initial-secret" and (.userJwt|fromjson|.RefreshToken)=="refresh-secret" and .loginTraceID=="trace ok"' "$RUN_DIR/payload" >/dev/null
native_callback_config "$RUN_DIR/query" "$RUN_DIR/payload" "$RUN_DIR/callback"
grep -q '^url = "http://127.0.0.1:49201/authorize?' "$RUN_DIR/callback"
grep -q 'userInfo=%7B%22UserInfo%22' "$RUN_DIR/callback"
jq '.identity.HostInfo.Api="https://www.trae.cn"' "$RUN_DIR/issued" > "$RUN_DIR/bad-issued"
check_failure native_callback_payload_invalid native_payload "$RUN_DIR/query" "$RUN_DIR/bad-issued" "$RUN_DIR/invalid-payload"
printf '%s\n' '{"members":[{"credentials":{"Token":"access-secret","RefreshToken":"refresh-secret"}}]}' > "$STATE_FILE"
printf '%s\n' '{"other":{"type":"oauth","access":"access-secret","refresh":"refresh-secret"},"trae-cn":{"type":"oauth","access":"old","refresh":"old"},"trae-cn#2":{"type":"oauth","access":"access-secret","refresh":"refresh-secret"}}' > "$CONFIG_HOME/magpie/plugin-auth.json"
native_reconcile
jq -en --argjson result "$NATIVE_RESULT" '$result.account_key=="trae-cn#2" and $result.uid_present==false' >/dev/null
[[ $NATIVE_RESULT != *secret* ]]
jq '."trae-cn"=."trae-cn#2"' "$CONFIG_HOME/magpie/plugin-auth.json" > "$RUN_DIR/dup"
mv "$RUN_DIR/dup" "$CONFIG_HOME/magpie/plugin-auth.json"
check_failure native_auth_ambiguous native_reconcile
printf '{}\n' > "$CONFIG_HOME/magpie/plugin-auth.json"
if native_reconcile; then fail absent_auth_accepted; fi
rm "$CONFIG_HOME/magpie/plugin-auth.json"
ln -s "$RUN_DIR/issued" "$CONFIG_HOME/magpie/plugin-auth.json"
check_failure native_auth_unsafe native_reconcile
rm "$CONFIG_HOME/magpie/plugin-auth.json"
export TRAE_ADMIN_PASSWORD=must-not-inherit HTTP_PROXY=http://secret-proxy BUN_OPTIONS=hostile NODE_OPTIONS=hostile MAGPIE_NO_ACCOUNTS=hostile LARK_CHANNEL=bridge
native_environment
[[ " ${NATIVE_ENV[*]} " == *' LARK_CHANNEL=bridge '* ]]
[[ " ${NATIVE_ENV[*]} " != *must-not-inherit* && " ${NATIVE_ENV[*]} " != *secret-proxy* && " ${NATIVE_ENV[*]} " != *hostile* ]]
check_failure gateway_output_requires_local_terminal_not_bridge finalize_terminal
unset LARK_CHANNEL
printf '%s\n' '{"providers":[{"id":"other","chosen":["preserve"],"models":[]},{"id":"trae-cn","chosen":["legacy"],"models":[{"id":"a"},{"id":"a"},{"id":"non-api","noAPI":true}],"proxy":"http://preserve","queueLimit":7,"routing":{"keep":true},"modelPrefs":{"keep":true}}]}' > "$RUN_DIR/providers"
model_save_body "$RUN_DIR/providers" "$RUN_DIR/model-body"
jq -e '.models==["legacy","a"] and .proxy=="http://preserve" and .queueLimit==7 and .noModels==false and .unlisted==false and (has("routing")|not) and (has("modelPrefs")|not)' "$RUN_DIR/model-body" >/dev/null
jq '.providers[1].models=[]' "$RUN_DIR/providers" > "$RUN_DIR/empty-providers"
check_failure model_catalog_invalid model_save_body "$RUN_DIR/empty-providers" "$RUN_DIR/empty-body"
for input in http://127.0.0.1:8080 https://example.test/ https://example.test/v1/ 'http://[::1]:8080/v1'; do gateway_url "$input"; [[ $GATEWAY_BASE == */v1 ]]; done
for input in 'http://u:p@host' 'https://host/?secret=x' 'http://host:0' 'http://host:65536' 'http://host/path' 'file:///tmp/a' 'http://host/#x'; do check_failure gateway_url_invalid gateway_url "$input"; done
# Curl spy confirms callback secrets stay in private config files, not argv.
curl() { printf '%s\n' "$@" > "$RUN_DIR/curl.argv"; printf '200'; }
timeout() { shift; "$@"; }
MODEL_BASE=http://127.0.0.1:49201
NATIVE_DEADLINE=$((SECONDS+10))
printf '{}\n' > "$RUN_DIR/api-response"
model_api state "$RUN_DIR/api-response"
! grep -Eq 'access-secret|refresh-secret|initial-secret' "$RUN_DIR/curl.argv"
# Real Bash child/FIFO/process-group lifecycle with a synthetic executable only.
(
    LOGIN_TIMEOUT=10
    MAGPIE_BIN=$RUN_DIR/fake-magpie
    printf '%s\n' '#!/bin/bash' 'set -eu' \
      '[[ $* == "plugin login trae-cn" ]]' \
      'work=${NATIVE_MAGPIE_GUARD_MARKER%/*}' \
      'printf %s "$NATIVE_MAGPIE_GUARD_NONCE" > "$NATIVE_MAGPIE_GUARD_MARKER"' \
      'printf "%s\\n" "https://www.trae.cn/authorization?device_id=dev&x_device_id=dev&login_trace_id=trace&auth_callback_url=http%3A%2F%2F127.0.0.1%3A49201%2Fauthorize"' \
      'while [[ ! -f $work/callback-done ]]; do sleep .05; done' \
      > "$MAGPIE_BIN"
    chmod 700 "$MAGPIE_BIN"
    printf '{"unrelated":{"keep":true}}\n' > "$CONFIG_HOME/magpie/plugin-auth.json"
    issue_tokens() { cp "$RUN_DIR/issued" "$2"; }
    curl() {
        [[ $* != *access-secret* && $* != *refresh-secret* ]]
        [[ -n $NATIVE_PID ]] && kill -0 "$NATIVE_PID"
        [[ -p $RUN_DIR/native.stdin ]]
        jq '. + {"trae-cn#new":{type:"oauth",access:"access-secret",refresh:"refresh-secret"}}' "$CONFIG_HOME/magpie/plugin-auth.json" > "$RUN_DIR/new-auth"
        mv "$RUN_DIR/new-auth" "$CONFIG_HOME/magpie/plugin-auth.json"
        : > "$RUN_DIR/callback-done"
        printf 200
    }
    native_login
    [[ -z $NATIVE_PID && -z $NATIVE_INPUT && $NATIVE_RESULT == *'trae-cn#new'* ]]
    [[ $NATIVE_RESULT != *secret* ]]
    jq -e '.unrelated.keep==true' "$CONFIG_HOME/magpie/plugin-auth.json" >/dev/null
)
# Finalization against an in-memory fixture API, not sockets or installed binaries.
model_api_start() { :; }
native_guard_confirm() { :; }
native_cleanup() { :; }
model_api() {
    case $1 in
        providers) cp "$RUN_DIR/providers" "$2";;
        state) printf '{"settings":{"preserve":"yes"}}\n' > "$2";;
        provider/save)
            jq --slurpfile body "$3" '.providers |= map(if .id=="trae-cn" then .chosen=$body[0].models | .noModels=false | .unlisted=false | .models|=map(if .noAPI then . else .on=true end) else . end)' "$RUN_DIR/providers" > "$RUN_DIR/next-providers"
            mv "$RUN_DIR/next-providers" "$RUN_DIR/providers"
            printf '{}\n' > "$2";;
        *) fail unexpected_api;;
    esac
}
finalize_models
jq -e '.model_publication.status=="COMPLETE" and .model_publication.model_count==1 and .model_publication.changed==true' "$STATE_FILE" >/dev/null
finalize_models
jq -e '.model_publication.changed==false' "$STATE_FILE" >/dev/null
# Gateway fixture verifies restricted key creation, resume and preservation.
(
    finalize_terminal() { exec {GATEWAY_TTY}>"$RUN_DIR/fake-terminal"; }
    printf '{"keys":[{"id":"existing","name":"preserve","models":["other/*"],"off":false,"accounts":["keep"]}]}\n' > "$RUN_DIR/key-store"
    printf '{"gateway":"http://127.0.0.1:3425","lan":false}\n' > "$RUN_DIR/gw-settings"
    model_api() {
        case $1 in
            settings) cp "$RUN_DIR/gw-settings" "$2";;
            providers) cp "$RUN_DIR/providers" "$2";;
            caller-keys) cp "$RUN_DIR/key-store" "$2";;
            caller-keys/add-key)
                jq --slurpfile body "$3" '.keys += [{id:"new-key",name:$body[0].name,off:false,models:[],accounts:[]}]' "$RUN_DIR/key-store" > "$RUN_DIR/keys-next"
                mv "$RUN_DIR/keys-next" "$RUN_DIR/key-store"
                printf '{}\n' > "$2";;
            caller-keys/copy-key) jq '.gateway|{secret}' "$STATE_FILE" > "$2";;
            caller-keys/models-key)
                jq '.keys |= map(if .id=="new-key" then .models=["trae-cn/*"] else . end)' "$RUN_DIR/key-store" > "$RUN_DIR/keys-next"
                mv "$RUN_DIR/keys-next" "$RUN_DIR/key-store"
                printf '{}\n' > "$2";;
            settings/lan) fail unauthorized_lan_write;;
            *) fail unexpected_gateway_api;;
        esac
    }
    GATEWAY_LAN=0 GATEWAY_URL= SKIP_GATEWAY=0
    finalize_gateway > "$RUN_DIR/gateway.stdout"
    jq -e '.gateway.status=="COMPLETE" and .gateway.shared==false and .gateway.url=="http://127.0.0.1:3425/v1"' "$STATE_FILE" >/dev/null
    jq -e '.keys|length==2 and .[0].accounts==["keep"] and .[1].models==["trae-cn/*"]' "$RUN_DIR/key-store" >/dev/null
    [[ ! -s $RUN_DIR/gateway.stdout ]]
    finalize_gateway > "$RUN_DIR/gateway.stdout"
    jq -e '.keys|length==2' "$RUN_DIR/key-store" >/dev/null
    grep -q 'API key: mp-' "$RUN_DIR/fake-terminal"
)
# No secrets accidentally emitted by the functions exercised above.
[[ $(stat -c %a "$RUN_DIR") == 700 ]]
printf 'native shell offline tests passed\n'
