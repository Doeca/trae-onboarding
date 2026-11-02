#!/usr/bin/env bash
# Short-lived loopback management only. Never start a permanent gateway.
finalize_state() {
    local filter=$1; shift
    jq "$@" "$filter" "$STATE_FILE" > "$RUN_DIR/finalize.state" || fail finalization_state_invalid
    mv "$RUN_DIR/finalize.state" "$STATE_FILE"
    state_save || fail encrypted_storage_failed
}
finalize_terminal() {
    local name
    while IFS= read -r name; do
        [[ $name != LARK_CHANNEL* || -z ${!name} ]] || fail gateway_output_requires_local_terminal_not_bridge
    done < <(compgen -e)
    if [[ -z ${GATEWAY_TTY:-} ]]; then
        { exec {GATEWAY_TTY}>/dev/tty; } 2>/dev/null || fail gateway_output_requires_local_terminal
    fi
    [[ -t $GATEWAY_TTY ]] || fail gateway_output_requires_local_terminal
}
model_api_start() {
    local port code
    MODEL_WEB_KEY=$(od -An -N 32 -tx1 /dev/urandom | tr -d ' \n')
    # Choose an unprivileged port; a collision fails closed, never reuses an existing session.
    port=$(od -An -N 2 -tu2 /dev/urandom | tr -d ' ')
    port=$((20000 + port % 40000))
    MODEL_BASE=http://127.0.0.1:$port
    rm -f -- "$RUN_DIR/model.cookies"
    native_start web web --no-open --addr "127.0.0.1:$port"
    while :; do
        native_output_check
        kill -0 "$NATIVE_PID" 2>/dev/null || fail model_api_start_failed
        if [[ -n $port ]]; then
            printf 'url = "%s/?k=%s"\n' "$MODEL_BASE" "$MODEL_WEB_KEY" > "$RUN_DIR/model.login"
            code=$(timeout 4 curl -q -4 -sS --noproxy '*' --proto '=http' --connect-timeout 1 --max-time 2 --max-filesize 8000000 --config "$RUN_DIR/model.login" --cookie-jar "$RUN_DIR/model.cookies" --output /dev/null --write-out '%{http_code}' 2> "$RUN_DIR/model.error") || code=
            if [[ $code == 200 || $code == 302 || $code == 303 ]] && grep -Eq '^[^#].*|^#HttpOnly_' "$RUN_DIR/model.cookies"; then return; fi
        fi
        kill -0 "$NATIVE_PID" 2>/dev/null || fail model_api_start_failed
        sleep .2
    done
}
model_api() {
    local endpoint=$1 output=$2 body=${3:-} code
    native_output_check
    [[ $endpoint =~ ^[a-z/-]+$ && $MODEL_BASE =~ ^http://127\.0\.0\.1:[0-9]+$ ]] || fail model_api_request_invalid
    local args=(-q -4 -sS --noproxy '*' --proto '=http' --connect-timeout 3 --max-time 20 --max-filesize 8000000
        --cookie "$RUN_DIR/model.cookies" --cookie-jar "$RUN_DIR/model.cookies"
        --header 'Content-Type: application/json' --header "Origin: $MODEL_BASE"
        --output "$output" --write-out '%{http_code}')
    [[ -z $body ]] || args+=(--data-binary "@$body")
    code=$(timeout 22 curl "${args[@]}" "$MODEL_BASE/api/$endpoint" 2> "$RUN_DIR/model.error") || fail model_api_request_failed
    [[ $code == 200 ]] && jq -e 'type=="object" and (.error|not)' "$output" >/dev/null 2>&1 || fail model_api_request_failed
}
model_save_body() {
    jq -e '
      def defaults: {fallback:[],contexts:{},outputs:{},compacts:{},proxy:"",accountProxies:{},maxConcurrency:null,queueLimit:0,queueWait:0,maxRPM:0,priceRate:0,pinUpstream:false};
      def unique_order: reduce .[] as $x ([]; if index($x)==null then .+[$x] else . end);
      [.providers[] | select(.id=="trae-cn")] |
      if length!=1 then error("provider") else .[0] end | . as $p |
      if (.models|type)!="array" or any(.models[]; type!="object" or (.id|type)!="string" or (.id|length)==0)
         or ((.chosen // [])|type)!="array" or any((.chosen // [])[]; type!="string") then error("catalog") else . end |
      [.models[] | select(.noAPI|not) | .id] as $eligible |
      if ($eligible|length)==0 then error("empty") else . end |
      (defaults | with_entries(.key as $k | if $p|has($k) then .value=$p[$k] else . end)) +
      {id:"trae-cn",models:((($p.chosen // [])+$eligible)|unique_order),noModels:false,unlisted:false} +
      (if $p.carriesCompaction then {nativeCompaction:($p.nativeCompaction // false)} else {} end)' "$1" > "$2" 2>/dev/null || fail model_catalog_invalid
}
model_fingerprint() {
    jq -S 'def defaults: {fallback:[],contexts:{},outputs:{},compacts:{},proxy:"",accountProxies:{},maxConcurrency:null,queueLimit:0,queueWait:0,maxRPM:0,priceRate:0,pinUpstream:false};
      {other:[.providers[]|select(.id!="trae-cn")|{id,chosen,noModels,unlisted}]|sort_by(.id),
      target:[.providers[]|select(.id=="trae-cn")|. as $p |
        (defaults | with_entries(.key as $k | if $p|has($k) then .value=$p[$k] else . end)) +
        {routing,affinity,sink,nativeCompaction}]}' "$1" > "$2" || fail model_provider_response_invalid
}
finalize_models() {
    finalize_state '.model_publication={status:"PENDING"}'
    model_api_start
    model_api providers "$RUN_DIR/model.before"
    native_guard_confirm
    model_save_body "$RUN_DIR/model.before" "$RUN_DIR/model.save"
    model_api state "$RUN_DIR/model.state-before"
    model_api providers "$RUN_DIR/model.second"
    model_api state "$RUN_DIR/model.state-second"
    jq -e --slurpfile second "$RUN_DIR/model.second" '.==$second[0]' "$RUN_DIR/model.before" >/dev/null &&
        jq -e --slurpfile second "$RUN_DIR/model.state-second" '.settings==$second[0].settings' "$RUN_DIR/model.state-before" >/dev/null || fail model_settings_changed_before_save
    local changed=false
    if ! jq -e --slurpfile body "$RUN_DIR/model.save" '.providers[]|select(.id=="trae-cn") |
      ((.chosen // [] | sort)==($body[0].models|sort)) and (.noModels|not) and (.unlisted|not) and all(.models[]|select(.noAPI|not); .on)' "$RUN_DIR/model.before" >/dev/null; then
        model_api provider/save "$RUN_DIR/model.saved" "$RUN_DIR/model.save"
        changed=true
    fi
    model_api providers "$RUN_DIR/model.after"
    model_save_body "$RUN_DIR/model.after" "$RUN_DIR/model.verify"
    jq -e '.providers[]|select(.id=="trae-cn") | . as $p |
      (.noModels|not) and (.unlisted|not) and all(.models[]|select(.noAPI|not); .on and (.id as $id | $p.chosen|index($id)!=null))' "$RUN_DIR/model.after" >/dev/null || fail model_publication_not_confirmed
    model_fingerprint "$RUN_DIR/model.before" "$RUN_DIR/model.fp-before"
    model_fingerprint "$RUN_DIR/model.after" "$RUN_DIR/model.fp-after"
    cmp -s "$RUN_DIR/model.fp-before" "$RUN_DIR/model.fp-after" || fail model_unrelated_settings_changed
    model_api state "$RUN_DIR/model.state-after"
    jq -e --slurpfile before "$RUN_DIR/model.state-before" '.settings==$before[0].settings' "$RUN_DIR/model.state-after" >/dev/null || fail model_unrelated_settings_changed
    jq --argjson changed "$changed" '.providers[] | select(.id=="trae-cn") | [.models[]|select(.noAPI|not)|.id] | unique |
      {status:"COMPLETE",provider:"trae-cn",model_count:length,models:.,changed:$changed,agent_filters_preserved:true,storage:"selected"}' "$RUN_DIR/model.after" > "$RUN_DIR/model.result"
    finalize_state '.model_publication=$result[0]' --slurpfile result "$RUN_DIR/model.result"
    native_cleanup
    emit models_published "$(jq -c '{provider,model_count,changed,agent_filters_preserved}' "$RUN_DIR/model.result")"
}
gateway_url() {
    # ASCII host/IPv4 or bracketed IPv6, no userinfo, query, fragments or escapes.
    local value=$1 port
    [[ $value =~ ^https?://(\[[0-9a-fA-F:]+\]|[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?)(:([0-9]{1,5}))?(/v1/?)?/?$ ]] || fail gateway_url_invalid
    port=${BASH_REMATCH[4]}
    [[ -z $port ]] || ((10#$port > 0 && 10#$port <= 65535)) || fail gateway_url_invalid
    value=${value%/}
    [[ $value == */v1 ]] || value+=/v1
    GATEWAY_BASE=$value
}
gateway_keys() {
    model_api caller-keys "$1"
    jq -e '.keys|type=="array" and all(.[]; type=="object" and (.id|type=="string" and length>0) and (.name|type=="string"))' "$1" >/dev/null || fail gateway_keys_response_invalid
}
gateway_owned() {
    jq --slurpfile state "$STATE_FILE" '[.keys[]|select(.name==$state[0].gateway.name)]' "$1" > "$RUN_DIR/gateway.matches"
    [[ $(jq length "$RUN_DIR/gateway.matches") -le 1 ]] || fail gateway_key_ambiguous
}
gateway_fingerprint() {
    jq -S --slurpfile state "$STATE_FILE" '[.keys[]|select(.id!=$state[0].gateway.id)|{id,name,off,models,accounts}]|sort_by(.id)' "$1" > "$2"
}
finalize_gateway() {
    [[ ${SKIP_GATEWAY:-0} != 1 ]] || return 0
    finalize_terminal
    [[ -z ${GATEWAY_URL:-} ]] || gateway_url "$GATEWAY_URL"
    if ! jq -e '.gateway!=null' "$STATE_FILE" >/dev/null; then
        { printf 'mp-'; od -An -N 36 -tx1 /dev/urandom | tr -d ' \n'; } > "$RUN_DIR/gateway.secret"
        { printf 'trae-onboarding-'; od -An -N 10 -tx1 /dev/urandom | tr -d ' \n'; } > "$RUN_DIR/gateway.name"
        finalize_state '.gateway={name:$name,secret:$secret,config:$config}' --rawfile name "$RUN_DIR/gateway.name" --rawfile secret "$RUN_DIR/gateway.secret" --arg config "$CONFIG_HOME/magpie"
    fi
    jq -e --arg config "$CONFIG_HOME/magpie" '.gateway.config==$config and (.gateway.secret|type=="string" and test("^mp-[A-Za-z0-9_-]+$")) and (.gateway.name|type=="string" and test("^trae-onboarding-[a-f0-9]+$"))' "$STATE_FILE" >/dev/null || fail gateway_config_mismatch
    finalize_state '.gateway.status="PENDING"'
    model_api_start
    model_api settings "$RUN_DIR/gateway.settings"
    model_api providers "$RUN_DIR/gateway.providers"
    native_guard_confirm
    jq -e '(.lan // false)|type=="boolean"' "$RUN_DIR/gateway.settings" >/dev/null || fail gateway_settings_response_invalid
    [[ -n ${GATEWAY_URL:-} ]] || gateway_url "$(jq -r '.gateway // ""' "$RUN_DIR/gateway.settings")"
    gateway_keys "$RUN_DIR/gateway.before"
    gateway_owned "$RUN_DIR/gateway.before"
    if [[ $(jq length "$RUN_DIR/gateway.matches") == 0 ]]; then
        jq -e '.gateway.id==null and (.gateway.create_started|not)' "$STATE_FILE" >/dev/null || fail gateway_key_unknown_outcome_requires_reconciliation
        finalize_state '.gateway.create_started=true'
        jq '.gateway|{name,secret}' "$STATE_FILE" > "$RUN_DIR/gateway.request"
        model_api caller-keys/add-key "$RUN_DIR/gateway.added" "$RUN_DIR/gateway.request"
        gateway_keys "$RUN_DIR/gateway.created"
        gateway_owned "$RUN_DIR/gateway.created"
    fi
    jq -e --slurpfile state "$STATE_FILE" 'length==1 and ($state[0].gateway.id==null or .[0].id==$state[0].gateway.id)' "$RUN_DIR/gateway.matches" >/dev/null || fail gateway_key_not_confirmed
    finalize_state '.gateway.id=$key[0][0].id' --slurpfile key "$RUN_DIR/gateway.matches"
    jq '.gateway|{key:.id}' "$STATE_FILE" > "$RUN_DIR/gateway.request"
    model_api caller-keys/copy-key "$RUN_DIR/gateway.copied" "$RUN_DIR/gateway.request"
    jq -e --slurpfile state "$STATE_FILE" '.secret==$state[0].gateway.secret' "$RUN_DIR/gateway.copied" >/dev/null || fail gateway_key_identity_mismatch
    jq -e '.[0].off|not' "$RUN_DIR/gateway.matches" >/dev/null || fail gateway_key_disabled_requires_manual_action
    if ! jq -e '.[0].models==["trae-cn/*"]' "$RUN_DIR/gateway.matches" >/dev/null; then
        jq '.gateway|{key:.id,models:["trae-cn/*"]}' "$STATE_FILE" > "$RUN_DIR/gateway.request"
        model_api caller-keys/models-key "$RUN_DIR/gateway.scoped" "$RUN_DIR/gateway.request"
    fi
    gateway_keys "$RUN_DIR/gateway.after"
    jq -e --slurpfile state "$STATE_FILE" '[.keys[]|select(.id==$state[0].gateway.id)] | length==1 and .[0].models==["trae-cn/*"] and (.[0].off|not)' "$RUN_DIR/gateway.after" >/dev/null || fail gateway_key_scope_not_confirmed
    gateway_fingerprint "$RUN_DIR/gateway.before" "$RUN_DIR/gateway.fp-before"
    gateway_fingerprint "$RUN_DIR/gateway.after" "$RUN_DIR/gateway.fp-after"
    cmp -s "$RUN_DIR/gateway.fp-before" "$RUN_DIR/gateway.fp-after" || fail gateway_other_keys_changed
    if [[ ${GATEWAY_LAN:-0} == 1 ]] && ! jq -e '.lan==true' "$RUN_DIR/gateway.settings" >/dev/null; then
        printf '{"on":true}\n' > "$RUN_DIR/gateway.request"
        model_api settings/lan "$RUN_DIR/gateway.shared" "$RUN_DIR/gateway.request"
        model_api settings "$RUN_DIR/gateway.settings"
        jq -e '.lan==true' "$RUN_DIR/gateway.settings" >/dev/null || fail gateway_sharing_not_confirmed
    fi
    finalize_state '.gateway += {status:"COMPLETE",url:$url,shared:($settings[0].lan // false)}' --arg url "$GATEWAY_BASE" --slurpfile settings "$RUN_DIR/gateway.settings"
    native_cleanup
    printf '\nMagpie gateway (sensitive; do not share terminal output)\nBase URL: %s\nAPI key: ' "$GATEWAY_BASE" >&"$GATEWAY_TTY"
    jq -r '.gateway.secret' "$STATE_FILE" >&"$GATEWAY_TTY"
    printf 'Key model scope: trae-cn/*\nConfiguration saved; gateway service must run separately.\nLoopback may trust local clients without checking this key.\n' >&"$GATEWAY_TTY"
    emit gateway_configured "$(jq -c '.gateway|{shared,service_started:false,key_scope:["trae-cn/*"]}' "$STATE_FILE")"
}
