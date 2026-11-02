#!/usr/bin/env bash
# Serial business state machine, curl cookies isolated by admin/member role.
identity_check() {
    local file=$1 identity=$2 active=${3:-0}
    jq -e --slurpfile credentials "$RUN_DIR/$identity.credentials" --slurpfile state "$STATE_FILE" \
        --argjson i "${TASK_INDEX:-0}" --argjson active "$active" '
      .Data as $d | $d.UserInfo as $u |
      ($u.Email|ascii_downcase)==($credentials[0].Email|ascii_downcase) and
      ($u.TenantID|type=="string" and length>0) and ($u.UserID|type=="string" and length>0) and
      ($state[0].tenant_id==null or $u.TenantID==$state[0].tenant_id) and
      (if $active==1 then $u.AccountType==1 and $u.RoleID==3 and $u.UserStatus==1 and
        $u.JoiningTime!=null and $u.JoiningTime!=0 and $d.IsAllowLogin==true and
        $u.UserID==$state[0].members[$i].uid else true end)' "$file" >/dev/null || fail identity_mismatch
}
member_credentials() {
    jq --argjson i "$TASK_INDEX" '.members[$i]|{Email:.email,Password:.password}' "$STATE_FILE" > "$RUN_DIR/member.credentials"
    rm -f "$RUN_DIR/member.cookies" "$RUN_DIR/member.referer"
}
member_info() {
    enterprise_read member /cloudide/api/v3/trae/GetUserInfo "$PROJECT/shell/attributes.json"
    cp "$HTTP_BODY" "$RUN_DIR/member.info"
    identity_check "$RUN_DIR/member.info" member 1
}
snapshot() {
    local department page total root
    enterprise_read admin /cloudide/api/v3/trae/GetUserInfo "$PROJECT/shell/attributes.json"
    cp "$HTTP_BODY" "$RUN_DIR/admin.info"
    identity_check "$RUN_DIR/admin.info" admin
    jq -e '.Data.UserInfo.RoleID==1 or .Data.UserInfo.RoleID==2' "$RUN_DIR/admin.info" >/dev/null || fail administrator_role_not_confirmed
    state_update '.tenant_id=$info[0].Data.UserInfo.TenantID' --slurpfile info "$RUN_DIR/admin.info"
    printf '%s\n' '{"IncludeMemberCount":false,"CountMode":"subtree"}' > "$RUN_DIR/request.json"
    enterprise_read admin /trae/gtm/tob/api/v1/department/list "$RUN_DIR/request.json"
    jq -e '(.RootDepartmentID|type=="string" and length>0) and (.Departments|type=="array") and
        (.Departments|all(.DepartmentID|type=="string" and length>0))' "$HTTP_BODY" >/dev/null || fail department_shape_unknown
    cp "$HTTP_BODY" "$RUN_DIR/departments.json"
    ROOT_DEPARTMENT=$(jq -r '.RootDepartmentID' "$HTTP_BODY")
    jq -r '([.RootDepartmentID]+[.Departments[].DepartmentID])|unique[]' "$HTTP_BODY" > "$RUN_DIR/departments.ids"
    printf '[]\n' > "$RUN_DIR/rows.json"
    while IFS= read -r department; do
        for ((page=1;page<=1000;page++)); do
            jq -n --arg department "$department" --argjson page "$page" \
                '{DepartmentID:$department,IncludeSubtree:false,Statuses:[1,9,2,4,3,11],Page:$page,PageSize:10}' > "$RUN_DIR/request.json"
            enterprise_read admin /trae/gtm/tob/api/v1/department/member_list "$RUN_DIR/request.json"
            jq -e '(.Data|type=="array") and (.Total|type=="number" and floor==. and .>=0) and
                (.Data|all(.UserInfo.UserID|type=="string"))' "$HTTP_BODY" >/dev/null || fail member_list_shape_unknown
            total=$(jq -r '.Total' "$HTTP_BODY")
            jq --slurpfile response "$HTTP_BODY" '. + $response[0].Data | unique_by(.UserInfo.UserID)' "$RUN_DIR/rows.json" > "$RUN_DIR/rows.next"
            mv "$RUN_DIR/rows.next" "$RUN_DIR/rows.json"
            ((page*10 >= total)) && break
            jq -e '.Data|length>0' "$HTTP_BODY" >/dev/null || fail member_pagination_inconsistent
        done
        ((page<=1000)) || fail member_pagination_limit
    done < "$RUN_DIR/departments.ids"
    jq -n --slurpfile info "$RUN_DIR/admin.info" --slurpfile rows "$RUN_DIR/rows.json" --slurpfile state "$STATE_FILE" \
        '{info:$info[0],rows:$rows[0],tasks:$state[0].members}' | jq -f "$PROJECT/shell/capacity.jq" > "$RUN_DIR/capacity.json" || fail full_capacity_unknown
}
task_phase() { jq -r --argjson i "$TASK_INDEX" '.members[$i].phase' "$STATE_FILE"; }
reconcile_member() {
    local count
    jq --slurpfile state "$STATE_FILE" --argjson i "$TASK_INDEX" \
        '[.[].UserInfo | select((.Email|ascii_downcase)==($state[0].members[$i].email|ascii_downcase))]' "$RUN_DIR/rows.json" > "$RUN_DIR/matches.json"
    count=$(jq length "$RUN_DIR/matches.json")
    ((count<=1)) || fail duplicate_email_identity
    if ((count==0)); then
        case $(task_phase) in PREPARED|MAILBOX_READY) return;; *) fail upstream_member_absent_reconcile_manually;; esac
    fi
    jq -e --slurpfile state "$STATE_FILE" --argjson i "$TASK_INDEX" \
        '.[0] | .RoleID==3 and .AccountType==1 and ($state[0].members[$i].uid==null or .UserID==$state[0].members[$i].uid)' "$RUN_DIR/matches.json" >/dev/null || fail invited_member_type_mismatch
    state_update '.members[$i].uid=$matches[0][0].UserID' --argjson i "$TASK_INDEX" --slurpfile matches "$RUN_DIR/matches.json"
    if jq -e '.[0]|.UserStatus==1 and .JoiningTime!=null and .JoiningTime!=0' "$RUN_DIR/matches.json" >/dev/null; then
        member_credentials; member_info
        case $(task_phase) in ACTIVE|MAGPIE_STARTED|TOKEN_ISSUING|REFRESH_ISSUED|TOKEN_EXCHANGING|TOKEN_READY|COMPLETE) ;; *) task_mark ACTIVE;; esac
    else
        case $(task_phase) in INVITE_SUBMITTING|PREPARED|MAILBOX_READY) task_mark INVITED;; esac
    fi
}
mail_form() {
    jq -rj --argjson i "$TASK_INDEX" '.members[$i].email | "mail="+@uri' "$STATE_FILE" > "$RUN_DIR/mail.form"
}
mail_apply() {
    mail_form
    http_request "$MAIL_BASE" /api/applymail "$RUN_DIR/mail.cookies" "$RUN_DIR/mail.form" 1 form || fail "$HTTP_ERROR"
    jq -e --slurpfile state "$STATE_FILE" --argjson i "$TASK_INDEX" '.user==$state[0].members[$i].email' "$HTTP_BODY" >/dev/null || fail mailbox_identity_mismatch
}
mail_wait() {
    local started now_time id email uri path link code
    started=$(jq -r --argjson i "$TASK_INDEX" '.members[$i].mail_wait_started // 0' "$STATE_FILE")
    if [[ $started == 0 ]]; then started=$(now); state_update '.members[$i].mail_wait_started=$t' --argjson i "$TASK_INDEX" --argjson t "$started"; fi
    member_credentials
    while (( $(now)-started < MAIL_TIMEOUT )); do
        now_time=$(now)
        if ((now_time-$(jq -r --argjson i "$TASK_INDEX" '.members[$i].mail_renewed_at // 0' "$STATE_FILE")>240)); then
            mail_apply; state_update '.members[$i].mail_renewed_at=$t' --argjson i "$TASK_INDEX" --argjson t "$now_time"
        fi
        mail_form; printf '&time=0&_=%s000' "$now_time" >> "$RUN_DIR/mail.form"
        http_request "$MAIL_BASE" /api/getmails "$RUN_DIR/mail.cookies" "$RUN_DIR/mail.form" 1 form || fail "$HTTP_ERROR"
        jq -e --slurpfile state "$STATE_FILE" --argjson i "$TASK_INDEX" \
            '.to==$state[0].members[$i].email and (.mail|type=="array" and length<=100) and (.mail|all(.id!=null))' "$HTTP_BODY" >/dev/null || fail inbox_identity_mismatch
        jq -r '.mail[].id|tostring|@uri' "$HTTP_BODY" > "$RUN_DIR/mail.ids"
        email=$(jq -r --argjson i "$TASK_INDEX" '.members[$i].email|@uri' "$STATE_FILE")
        while IFS= read -r id; do
            path=/api/raw-html/$email/$id
            http_request "$MAIL_BASE" "$path" "$RUN_DIR/mail.cookies" - 1 form 1 || fail "$HTTP_ERROR"
            # HTML is never executed. Only allowlisted enterprise links are considered.
            jq -Rs '[gsub("&amp;";"&") | scan("https://console\\.enterprise\\.trae\\.cn/invite-email\\?[^\\s\"\u0027<>]+") ] | unique[]' "$HTTP_BODY" > "$RUN_DIR/mail.links"
            while IFS= read -r link; do
                # jq lines retain quotes; decode and require exactly one conservative URL-safe code.
                code=$(printf '%s\n' "$link" | jq -r '[. | splits("[?&]") | select(startswith("code=")) | ltrimstr("code=")] | if length==1 and (.[0]|test("^[A-Za-z0-9_-]+$")) then .[0] else empty end')
                [[ -n $code ]] || continue
                printf %s "$code" > "$RUN_DIR/invite.code"
                jq -n --rawfile code "$RUN_DIR/invite.code" '{CodeType:1,LinkCode:$code}' > "$RUN_DIR/request.json"
                http_request "$BASE" /trae/gtm/tob/api/v1/account/get_code_info "$RUN_DIR/member.cookies" "$RUN_DIR/request.json" 1 || fail "$HTTP_ERROR"
                jq -e --slurpfile state "$STATE_FILE" --argjson i "$TASK_INDEX" '.Data|(.Email|ascii_downcase)==$state[0].members[$i].email and .TenantID==$state[0].tenant_id and .AccountType==1' "$HTTP_BODY" >/dev/null || fail invitation_identity_mismatch
                state_update '.members[$i].invite_code=$code' --argjson i "$TASK_INDEX" --rawfile code "$RUN_DIR/invite.code"
                task_mark INVITE_VERIFIED; return
            done < "$RUN_DIR/mail.links"
        done < "$RUN_DIR/mail.ids"
        sleep "$POLL_SECONDS"
    done
    fail invitation_mail_timeout
}
issue_tokens() {
    local query=$1 output=$2
    member_credentials
    jq -r --arg base "$BASE" 'to_entries | map(.key as $k | .value[] | ($k|@uri)+"="+(.|@uri)) | $base+"/authorization?"+join("&")' "$query" > "$RUN_DIR/member.referer"
    member_info
    task_mark TOKEN_ISSUING
    jq '{DID:.device_id[0],SourceType:5}' "$query" > "$RUN_DIR/request.json"
    http_request "$BASE" /cloudide/api/v3/trae/oauth/GetRefreshToken "$RUN_DIR/member.cookies" "$RUN_DIR/request.json" 0 || fail "$HTTP_ERROR"
    jq -e '.Data.RefreshToken|type=="string" and length>0' "$HTTP_BODY" >/dev/null || fail refresh_issuance_failed
    state_update '.members[$i].initial_refresh=$response[0].Data' --argjson i "$TASK_INDEX" --slurpfile response "$HTTP_BODY"
    task_mark REFRESH_ISSUED
    jq --argjson i "$TASK_INDEX" '.members[$i].initial_refresh|{RefreshToken}' "$STATE_FILE" > "$RUN_DIR/request.json"
    task_mark TOKEN_EXCHANGING
    http_request "$BASE" /cloudide/api/v3/trae/oauth/ExchangeToken "$RUN_DIR/member.cookies" "$RUN_DIR/request.json" 0 || fail "$HTTP_ERROR"
    jq -e --argjson now "$(($(now)*1000))" '.Data|(.Token|type=="string" and length>0) and (.RefreshToken|type=="string" and length>0) and .TokenExpireAt>$now and .RefreshExpireAt>$now' "$HTTP_BODY" >/dev/null || fail token_pair_invalid
    state_update '.members[$i].credentials=$response[0].Data | .members[$i].credential_version=((.members[$i].credential_version//0)+1)' --argjson i "$TASK_INDEX" --slurpfile response "$HTTP_BODY"
    task_mark TOKEN_READY
    jq --argjson i "$TASK_INDEX" --slurpfile info "$RUN_DIR/member.info" '.members[$i]|{initial_refresh,credentials,identity:$info[0]}' "$STATE_FILE" > "$output"
}
advance_member() {
    reconcile_member
    [[ $(task_phase) == COMPLETE ]] && return
    if [[ $(task_phase) == PREPARED ]]; then mail_apply; task_mark MAILBOX_READY; fi
    if [[ $(task_phase) == MAILBOX_READY ]]; then
        snapshot; reconcile_member
        if [[ $(task_phase) == MAILBOX_READY ]]; then
            jq -e '.reserved_occupied+.pending<=.total' "$RUN_DIR/capacity.json" >/dev/null || fail full_capacity_changed
            jq -e --slurpfile state "$STATE_FILE" --argjson i "$TASK_INDEX" '([.RootDepartmentID]+[.Departments[].DepartmentID])|index($state[0].members[$i].department_id)!=null' "$RUN_DIR/departments.json" >/dev/null || fail selected_department_disappeared
            jq --argjson i "$TASK_INDEX" '.members[$i]|{Members:[{Email:.email,Name:("API Test "+.id[0:8]),RoleID:3,AccountType:1,DepartmentIDs:[.department_id]}],SendInvite:true}' "$STATE_FILE" > "$RUN_DIR/invite.request"
            task_mark INVITE_SUBMITTING
            # Even a failed/unknown response must be reconciled, never resent.
            http_request "$BASE" /trae/gtm/tob/api/v1/account/member/create "$RUN_DIR/admin.cookies" "$RUN_DIR/invite.request" 0 || true
            snapshot; reconcile_member
        fi
    fi
    [[ $(task_phase) != INVITED ]] || mail_wait
    if [[ $(task_phase) == INVITE_VERIFIED ]]; then
        member_credentials
        jq --argjson i "$TASK_INDEX" '.members[$i]|{Email:.email,Password:.password,Name:"",SendEmailType:1,Code:.invite_code}' "$STATE_FILE" > "$RUN_DIR/register.request"
        task_mark REGISTER_SUBMITTING
        http_request "$BASE" /trae/gtm/tob/api/v1/account/register "$RUN_DIR/member.cookies" "$RUN_DIR/register.request" 0 || fail "$HTTP_ERROR"
        jq -e '.Data==true and .AccountType==1' "$HTTP_BODY" >/dev/null || fail registration_not_confirmed
        member_info; task_mark ACTIVE
    fi
    case $(task_phase) in
        REGISTER_SUBMITTING) fail registration_outcome_unknown_do_not_repeat;;
        ACTIVE|MAGPIE_STARTED|TOKEN_ISSUING|REFRESH_ISSUED|TOKEN_EXCHANGING|TOKEN_READY) ;;
        *) fail unexpected_member_phase;;
    esac
    if native_reconcile; then task_mark COMPLETE "$(jq -cn --argjson result "$NATIVE_RESULT" '{magpie:$result}')"; return; fi
    task_mark MAGPIE_STARTED
    native_login
    task_mark COMPLETE "$(jq -cn --argjson result "$NATIVE_RESULT" '{magpie:$result}')"
}
run_batch() {
    local id
    while true; do
        state_update '.status="RUNNING"'
        snapshot; emit capacity "$(<"$RUN_DIR/capacity.json")"
        TASK_INDEX=$(jq '[.members|to_entries[]|select(.value.phase!="COMPLETE")][0].key // -1' "$STATE_FILE")
        if [[ $TASK_INDEX == -1 ]] && jq -e '.available>0' "$RUN_DIR/capacity.json" >/dev/null; then
            id=$(random_hex 8)
            printf 'Aa9!%s' "$(random_hex 24)" > "$RUN_DIR/new.password"
            state_update '.members += [{id:$id,email:("apitest"+$id+"@nimail.cn"),password:$password,department_id:$root,phase:"PREPARED"}]' --arg id "$id" --rawfile password "$RUN_DIR/new.password" --arg root "$ROOT_DEPARTMENT"
            TASK_INDEX=$(jq '.members|length-1' "$STATE_FILE")
        fi
        if [[ $TASK_INDEX != -1 ]]; then advance_member; sleep "$POLL_SECONDS"; continue; fi
        jq -e '.active==.total' "$RUN_DIR/capacity.json" >/dev/null || fail remaining_full_seats_reserved_or_inactive_requires_manual_action
        state_update '.status="PUBLISHING_MODELS"'
        finalize_models
        if [[ $SKIP_GATEWAY == 0 ]]; then state_update '.status="CONFIGURING_GATEWAY"'; finalize_gateway; fi
        state_update '.status="FULL" | del(.reason)'
        emit all_full_seats_occupied
        [[ $WATCH == 1 ]] || return 0
        sleep "$POLL_SECONDS"
    done
}
