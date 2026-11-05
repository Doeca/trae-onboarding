#!/usr/bin/env bash
# Bash runtime: curl + jq, no Python invocation or browser automation.
set -Eeuo pipefail
set +x
umask 077
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
TMP=$PROJECT/tmp
source "$PROJECT/shell/common.sh"
source "$PROJECT/shell/bootstrap.sh"
source "$PROJECT/shell/service.sh"
source "$PROJECT/shell/native.sh"
source "$PROJECT/shell/finalize.sh"

usage() {
    printf '%s\n' 'Usage: bash onboarding.sh bootstrap|doctor|check|run|status|publish-models|setup-gateway [options]' \
      '  bootstrap: ask local terminal for install/config paths and consent; no account login' \
      '  doctor: offline environment validation only' \
      '  --state-dir DIR        durable Bash state under project tmp (default tmp/bash-onboarding)' \
      '  --env-file FILE        administrator settings (default .env; parsed, never executed)' \
      '  --poll-seconds N       8..3600, default 15' \
      '  --mail-timeout N       30..600, default 180' \
      '  --login-timeout N      30..600, default 120' \
      '  --yes-fill-full-seats --accept-disposable-mailbox  required for run' \
      '  --watch --retry-mail --skip-gateway  run options' \
      '  --gateway-lan --gateway-url URL   explicit shared gateway options' \
      'All install/config locations come from interactive bootstrap. No Python state auto-import.'
}
COMMAND=${1:---help}; (($#==0)) || shift
STATE_DIR=$TMP/bash-onboarding ENV_FILE=$PROJECT/.env
POLL_SECONDS=15 MAIL_TIMEOUT=180 LOGIN_TIMEOUT=120 WATCH=0 RETRY_MAIL=0 SKIP_GATEWAY=0
GATEWAY_LAN=0 GATEWAY_URL= ACCEPT=0 FILL=0 TASK_INDEX=0
while (($#)); do
    case $1 in
        --state-dir|--env-file|--poll-seconds|--mail-timeout|--login-timeout|--gateway-url)
            (($#>=2)) || { usage; exit 2; }
            case $1 in
                --state-dir) STATE_DIR=$2;; --env-file) ENV_FILE=$2;; --poll-seconds) POLL_SECONDS=$2;;
                --mail-timeout) MAIL_TIMEOUT=$2;; --login-timeout) LOGIN_TIMEOUT=$2;; --gateway-url) GATEWAY_URL=$2;;
            esac; shift 2;;
        --watch) WATCH=1;shift;; --retry-mail) RETRY_MAIL=1;shift;; --skip-gateway) SKIP_GATEWAY=1;shift;;
        --gateway-lan) GATEWAY_LAN=1;shift;; --accept-disposable-mailbox) ACCEPT=1;shift;;
        --yes-fill-full-seats) FILL=1;shift;; --help|-h) usage;exit 0;;
        *) usage;exit 2;;
    esac
done
case $COMMAND in --help|-h|help) usage;exit 0;; bootstrap|doctor|check|run|status|publish-models|setup-gateway) ;; *) usage;exit 2;; esac
[[ $BASH_VERSINFO -ge 4 ]] || { printf 'Bash 4.4+ required\n' >&2; exit 1; }
if [[ $COMMAND == bootstrap ]]; then bootstrap_interactive; exit; fi
for tool in jq gpg curl flock timeout realpath stat sync mktemp od tr grep cmp mkfifo setsid sha256sum date sleep; do command -v "$tool" >/dev/null || { printf 'Missing prerequisite: %s; run bootstrap from local terminal.\n' "$tool" >&2; exit 1; }; done
for value in "$POLL_SECONDS" "$MAIL_TIMEOUT" "$LOGIN_TIMEOUT"; do [[ $value =~ ^[1-9][0-9]{0,3}$ ]] || fail invalid_numeric_option; done
((POLL_SECONDS>=8 && POLL_SECONDS<=3600 && MAIL_TIMEOUT>=30 && MAIL_TIMEOUT<=600 && LOGIN_TIMEOUT>=30 && LOGIN_TIMEOUT<=600)) || fail invalid_timeout_range
[[ $COMMAND == run || ($WATCH == 0 && $RETRY_MAIL == 0 && $SKIP_GATEWAY == 0) ]] || fail run_only_option
[[ $COMMAND != run || ($FILL == 1 && $ACCEPT == 1) ]] || fail run_requires_explicit_consent
if [[ $COMMAND == setup-gateway || ($COMMAND == run && $SKIP_GATEWAY == 0) ]]; then
    [[ -z ${LARK_CHANNEL:-} && -z ${LARK_CHANNEL_HOME:-} && -z ${LARKSUITE_CLI_CONFIG_DIR:-} ]] || fail gateway_output_requires_local_terminal_not_bridge
    { exec {GATEWAY_TTY}<>/dev/tty; } 2>/dev/null || fail gateway_output_requires_local_terminal
    [[ -t $GATEWAY_TTY ]] || fail gateway_output_requires_local_terminal
fi
[[ $COMMAND == run || $COMMAND == setup-gateway || ($GATEWAY_LAN == 0 && -z $GATEWAY_URL) ]] || fail gateway_only_option
[[ -z $GATEWAY_URL ]] || gateway_url "$GATEWAY_URL"
trap cleanup EXIT
trap 'fail unexpected_shell_failure' ERR
trap 'exit 130' INT TERM
if [[ $COMMAND == status ]]; then
    state_open
    jq '{event:"status",status,reason,model_publication,gateway_status:.gateway.status,tasks:[.members[]|{id,email,phase}]}' "$STATE_FILE"
    exit
fi
if [[ ! -f $TMP/shell-install.json && $COMMAND != doctor ]]; then bootstrap_interactive; fi
load_install_config
environment_check
[[ $COMMAND != doctor ]] || exit 0
state_open
if jq -e '.config_home!=null' "$STATE_FILE" >/dev/null; then
    jq -e --arg config "$CONFIG_HOME" '.config_home==$config' "$STATE_FILE" >/dev/null || fail batch_config_mismatch
else state_update '.config_home=$config' --arg config "$CONFIG_HOME"; fi
native_preflight
case $COMMAND in
    check) admin_load; snapshot; emit preflight_passed "$(<"$RUN_DIR/capacity.json")";;
    run)
        if [[ $RETRY_MAIL == 1 ]]; then state_update '.members |= map(if .phase=="INVITED" then del(.mail_wait_started) else . end)'; fi
        admin_load; run_batch;;
    publish-models|setup-gateway)
        jq -e '.members|length>0 and all(.phase=="COMPLETE")' "$STATE_FILE" >/dev/null || fail completed_members_required
        if [[ $COMMAND == publish-models ]]; then finalize_models
        else
            jq -e '.model_publication.status=="COMPLETE"' "$STATE_FILE" >/dev/null || fail completed_models_required
            finalize_gateway
        fi;;
esac
