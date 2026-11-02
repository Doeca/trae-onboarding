#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
PROJECT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$PROJECT/tmp
mkdir -p "$TMP"
source "$PROJECT/shell/common.sh"
source "$PROJECT/shell/service.sh"
TEST_ROOT=$(mktemp -d "$TMP/test-shell-core.XXXXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT
STATE_DIR=$TEST_ROOT/state
state_open
trap 'rm -rf -- "$RUN_DIR" "$TEST_ROOT"' EXIT
TASK_INDEX=0
state_update '.members=[{id:"one",email:"a@example.test",password:"offline-secret",phase:"PREPARED"}]'
! grep -q offline-secret "$STATE_DIR/state.gpg"
task_mark INVITED
[[ $(task_phase) == INVITED ]]
timeout 35 gpg --homedir "$STATE_DIR/gpg" --batch --no-options --pinentry-mode loopback --passphrase-file "$STATE_KEY" --decrypt "$STATE_DIR/state.gpg" 2>/dev/null | jq -e '.members[0].phase=="INVITED"' >/dev/null
printf '%s\n' 'TRAE_ADMIN_ACCOUNT="admin@example.test"' "TRAE_ADMIN_PASSWORD='literal\$(not-executed)'" > "$TEST_ROOT/env"
ENV_FILE=$TEST_ROOT/env
admin_load
jq -e '.Password=="literal$(not-executed)"' "$RUN_DIR/admin.credentials" >/dev/null
jq -n '{info:{AccountQuotaSummary:{Full:{TotalQuota:4,OccupiedCount:1,ActiveCount:1}}},rows:[{UserInfo:{Email:"joined@example.test",UserID:"1",AccountType:1,JoiningTime:1}},{UserInfo:{Email:"invite@example.test",UserID:"2",AccountType:1,JoiningTime:0}}],tasks:[{email:"invite@example.test",phase:"INVITED"},{email:"new@example.test",phase:"PREPARED"}]}' | jq -f "$PROJECT/shell/capacity.jq" | jq -e '.available==1 and .pending==2' >/dev/null
if printf '%s\n' '{"info":{"AccountQuotaSummary":{"Full":{"TotalQuota":4,"OccupiedCount":1,"ActiveCount":2}}},"rows":[],"tasks":[]}' | jq -f "$PROJECT/shell/capacity.jq" > /dev/null 2>&1; then exit 1; fi
# Unknown invite is never resent or replaced.
state_update '.members[0].phase="INVITE_SUBMITTING"'
printf '[]\n' > "$RUN_DIR/rows.json"
if (reconcile_member) > "$TEST_ROOT/error" 2>&1; then exit 1; fi
grep -q upstream_member_absent_reconcile_manually "$TEST_ROOT/error"
! grep -q offline-secret "$TEST_ROOT/error"
# Fake two-seat world drives the actual orchestrator, without network.
state_update '.members=[] | .status="READY"'
COUNT=0 PUBLISHED=0 GATEWAY=0 WATCH=0 SKIP_GATEWAY=0 POLL_SECONDS=8
snapshot() {
 ROOT_DEPARTMENT=root
 COUNT=$(jq '[.members[]|select(.phase=="COMPLETE")]|length' "$STATE_FILE")
 jq -n --argjson count "$COUNT" '{total:2,occupied:$count,active:$count,available:(2-$count),pending:0}' > "$RUN_DIR/capacity.json"
}
advance_member() { task_mark COMPLETE; }
sleep() { :; }
finalize_models() { [[ $(jq '.members|length' "$STATE_FILE") == 2 ]]; PUBLISHED=1; state_update '.model_publication.status="COMPLETE"'; }
finalize_gateway() { [[ $PUBLISHED == 1 ]]; GATEWAY=1; }
run_batch
[[ $GATEWAY == 1 && $(jq -r .status "$STATE_FILE") == FULL ]]
run_batch
[[ $(jq '.members|length' "$STATE_FILE") == 2 ]]
printf 'Bash core tests passed\n'
