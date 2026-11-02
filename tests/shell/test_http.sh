#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
PROJECT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$PROJECT/tmp
source "$PROJECT/shell/common.sh"
RUN_DIR=$(mktemp -d "$TMP/test-shell-http.XXXXXXXX")
trap 'rm -rf -- "$RUN_DIR"' EXIT
printf '{}\n' > "$RUN_DIR/request.json"
ATTEMPTS=0 PROBES=0 MODE=retry
http_probe() { PROBES=$((PROBES+1)); printf probe >> "$RUN_DIR/probes"; return 0; }
# Command substitution runs in a subshell: record counts on disk.
timeout() {
 shift
 [[ $1 == curl ]] || return 1
 shift
 local output= a
 while (($#)); do
   a=$1;shift
   if [[ $a == --output ]]; then output=$1;shift; fi
 done
 local n=0
 [[ ! -f $RUN_DIR/count ]] || n=$(<"$RUN_DIR/count")
 n=$((n+1));printf %s "$n" > "$RUN_DIR/count"
 case $MODE in
   retry) if ((n==1)); then return 28; fi;printf '{"code":0}' > "$output";printf 200;;
   business) printf '{"code":30011}' > "$output";printf 200;;
   unknown) return 28;;
   malformed) printf '<html>not json</html>' > "$output";printf 200;;
 esac
}
http_request "$BASE" /test "$RUN_DIR/admin.cookies" "$RUN_DIR/request.json" 1
[[ $(<"$RUN_DIR/count") == 2 && $(<"$RUN_DIR/probes") == probe ]]
rm "$RUN_DIR/count" "$RUN_DIR/probes"
MODE=unknown
if http_request "$BASE" /test "$RUN_DIR/member.cookies" "$RUN_DIR/request.json" 0; then exit 1; fi
[[ $HTTP_ERROR == request_outcome_unknown && $(<"$RUN_DIR/count") == 1 && ! -f $RUN_DIR/probes ]]
rm "$RUN_DIR/count"
MODE=business
if http_request "$BASE" /test "$RUN_DIR/member.cookies" "$RUN_DIR/request.json" 1; then exit 1; fi
[[ $HTTP_ERROR == upstream_business_failure && $(<"$RUN_DIR/count") == 1 && ! -f $RUN_DIR/probes ]]
MODE=malformed
if http_request "$BASE" /test "$RUN_DIR/member.cookies" "$RUN_DIR/request.json" 0; then exit 1; fi
[[ $HTTP_ERROR == invalid_response_shape ]]
printf 'Bash HTTP tests passed\n'
