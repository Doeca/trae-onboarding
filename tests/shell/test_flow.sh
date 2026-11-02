#!/usr/bin/env bash
# Actual service stages with synthetic endpoint replies. No native login/network.
set -Eeuo pipefail
umask 077
PROJECT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$PROJECT/tmp
source "$PROJECT/shell/common.sh"
source "$PROJECT/shell/service.sh"
T=$(mktemp -d "$TMP/test-shell-flow.XXXXXXXX")
STATE_DIR=$T/state
state_open
trap 'rm -rf -- "$RUN_DIR" "$T"' EXIT
TASK_INDEX=0 POLL_SECONDS=8 MAIL_TIMEOUT=30
state_update '.tenant_id="tenant" | .members=[{id:"one",email:"member@example.test",password:"fake-only",department_id:"root",phase:"PREPARED"}]'
printf '[]\n' > "$RUN_DIR/rows.json"
INVITES=0 REGISTERS=0 LOGINS=0
snapshot() { printf '{"total":1,"active":0,"occupied":0,"pending":1,"reserved_occupied":0,"available":0}' > "$RUN_DIR/capacity.json"; printf '{"RootDepartmentID":"root","Departments":[]}' > "$RUN_DIR/departments.json"; }
member_info() { printf '{"Data":{"IsAllowLogin":true,"UserInfo":{"Email":"member@example.test","UserID":"u1","TenantID":"tenant","AccountType":1,"RoleID":3,"JoiningTime":1,"UserStatus":1,"Scope":"saas"}},"HostInfo":{"Api":"https://console.enterprise.trae.cn","Console":"https://console.enterprise.trae.cn","Core":"https://console.enterprise.trae.cn"}}' > "$RUN_DIR/member.info"; }
http_request() {
 local path=$2
 HTTP_BODY=$RUN_DIR/http.body
 case $path in
 /api/applymail) printf '{"success":true,"user":"member@example.test"}' > "$HTTP_BODY";;
 /trae/gtm/tob/api/v1/account/member/create)
   INVITES=$((INVITES+1));printf '[{"UserInfo":{"Email":"member@example.test","UserID":"u1","RoleID":3,"AccountType":1,"JoiningTime":0,"UserStatus":2}}]' > "$RUN_DIR/rows.json"
   printf '{"code":0,"SuccessCount":1,"Failures":[]}' > "$HTTP_BODY";;
 /api/getmails) printf '{"success":true,"to":"member@example.test","mail":[{"id":"mail-1"}]}' > "$HTTP_BODY";;
 /api/raw-html/*) printf '<a href="https://console.enterprise.trae.cn/invite-email?x=1&amp;code=fake-code">Invite</a>' > "$HTTP_BODY";;
 /trae/gtm/tob/api/v1/account/get_code_info)
   jq -e '.LinkCode=="fake-code"' "$4" >/dev/null
   printf '{"code":0,"Data":{"Email":"member@example.test","TenantID":"tenant","AccountType":1}}' > "$HTTP_BODY";;
 /trae/gtm/tob/api/v1/account/register)
   REGISTERS=$((REGISTERS+1)); printf '{"code":0,"Data":true,"AccountType":1}' > "$HTTP_BODY";;
 /cloudide/api/v3/trae/oauth/GetRefreshToken)
   printf '{"code":0,"Data":{"RefreshToken":"initial","RefreshExpireAt":9999999999999}}' > "$HTTP_BODY";;
 /cloudide/api/v3/trae/oauth/ExchangeToken)
   printf '{"code":0,"Data":{"Token":"fake-access","RefreshToken":"fake-refresh","TokenExpireAt":9999999999999,"RefreshExpireAt":9999999999999}}' > "$HTTP_BODY";;
 *) exit 90;;
 esac
}
native_reconcile() { return 1; }
native_login() {
 LOGINS=$((LOGINS+1))
 printf '{"device_id":["did"],"x_device_id":["did"],"login_trace_id":["trace"],"auth_callback_url":["http://127.0.0.1:12345/authorize"]}' > "$RUN_DIR/query"
 issue_tokens "$RUN_DIR/query" "$RUN_DIR/issued"
 jq -e '.credentials.RefreshToken=="fake-refresh" and .identity.Data.UserInfo.UserID=="u1"' "$RUN_DIR/issued" >/dev/null
 NATIVE_RESULT='{"account_key":"trae-cn","storage":"selected"}'
}
advance_member
[[ $INVITES == 1 && $REGISTERS == 1 && $LOGINS == 1 && $(task_phase) == COMPLETE ]]
printf 'Bash endpoint flow test passed\n'
