#!/usr/bin/env bash
# Offline function doubles: package managers, sudo and network never run for real.
set -euo pipefail
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
[[ ! -L $REPO/tmp ]] || exit 1
mkdir -p -m 700 "$REPO/tmp"
SUITE=$(mktemp -d "$REPO/tmp/install-deps-tests.XXXXXXXX")
trap 'rm -rf -- "$SUITE"' EXIT
source "$REPO/shell/install-deps.sh"
fail() { printf 'FAIL:%s\n' "$1" >&2; exit 1; }

fixture() {
    PROJECT=$(mktemp -d "$SUITE/case.XXXXXXXX") TMP=''
    TMP=$PROJECT/tmp
    mkdir -m 700 "$TMP"
    exec {BOOTSTRAP_TTY}<>"$PROJECT/tty"
    OSTYPE=linux-gnu
    TEST_MISSING='jq' TEST_MANAGER=apt-get TEST_ROOT=yes TEST_CA=yes
    TEST_DENY=no TEST_FAIL='' TEST_REPAIR=yes TEST_SUDO=yes TEST_CA_REPAIR=yes
    TEST_DISTRO=debian TEST_CODENAME=bookworm
    : > "$PROJECT/calls"
    _bootstrap_deps_release() { deps_id=$TEST_DISTRO; deps_codename=$TEST_CODENAME; }
    _bootstrap_deps_root() { [[ $TEST_ROOT == yes ]]; }
    _bootstrap_deps_keyring_ready() { return 0; }
    _bootstrap_deps_ca_ready() {
        [[ $TEST_CA == yes || ( -e $PROJECT/installed && $TEST_CA_REPAIR == yes ) ]]
    }
    _bootstrap_deps_have() {
        case $1 in
            apt-get|dnf|yum) [[ $1 == "$TEST_MANAGER" ]]; return ;;
            sudo) [[ $TEST_SUDO == yes ]]; return ;;
        esac
        if [[ ! -e $PROJECT/installed || $TEST_REPAIR != yes ]]; then
            [[ " $TEST_MISSING " != *" $1 "* ]] || return 1
        fi
        return 0
    }
    _bootstrap_confirm() {
        printf 'consent\n' >> "$PROJECT/calls"
        [[ $TEST_DENY != yes ]]
    }
    # Portable test metadata adapter; production still requires GNU stat.
    stat() {
        if [[ $(builtin command uname -s) == Darwin ]]; then
            case $2 in
                %u) builtin command stat -f %u "${@: -1}" ;;
                %a) builtin command stat -f %Lp "${@: -1}" ;;
                *) return 99 ;;
            esac
        else builtin command stat "$@"; fi
    }
    _bootstrap_deps_helper() { "$@"; }
    dpkg() { [[ $1 == --print-architecture ]]; printf amd64; }
    rpm() { if [[ $2 == '%{rhel}' ]]; then printf 9; else printf x86_64; fi; }
    apt-get() { fake_manager apt-get "$@"; }
    dnf() { fake_manager dnf "$@"; }
    yum() { fake_manager yum "$@"; }
    sudo() {
        [[ $(<"$PROJECT/calls") == *consent* ]] || return 91
        printf 'sudo\n' >> "$PROJECT/calls"
        [[ $1 == -- ]] || return 92
        shift
        while [[ $1 == *=* ]]; do export "$1"; shift; done
        "$@"
    }
    curl() { fail unexpected_network; }
}
fake_manager() {
    local manager=$1; shift
    [[ $(<"$PROJECT/calls") == *consent* ]] || return 93
    [[ $TMPDIR == "$PROJECT/tmp/"*/tmp && $TEMP == "$TMPDIR" && $TMP == "$TMPDIR" && $XDG_CACHE_HOME == "$PROJECT/tmp/"*/cache ]] || return 94
    local operation='' arg
    for arg in "$@"; do [[ $arg != update && $arg != install ]] || operation=$arg; done
    printf '%s %s\n' "$manager" "$operation" >> "$PROJECT/calls"
    printf '%s\n' "$@" > "$PROJECT/$operation.args"
    printf 'SYNTHETIC_PRIVATE_INSTALLER_OUTPUT\n'
    [[ $TEST_FAIL != "$operation" ]] || return 42
    [[ $operation != install ]] || : > "$PROJECT/installed"
}
expect_failure() {
    local expected=$1 output rc=0
    output=$(_bootstrap_install_dependencies 2>&1) || rc=$?
    [[ $rc != 0 && $output == *"FAIL:$expected"* && $output != *"$PROJECT"* && $output != *SYNTHETIC_PRIVATE* ]] || {
        printf 'Wrong failure: %s\n' "$output" >&2; return 1;
    }
}
case_noop() {
    fixture; TEST_MISSING=''
    _bootstrap_install_dependencies
    [[ ! -s $PROJECT/calls && ! -s $PROJECT/tty ]]
}
case_denied() {
    fixture; TEST_DENY=yes; TEST_ROOT=no
    expect_failure bootstrap_consent_declined
    [[ $(<"$PROJECT/calls") == consent && ! -e $PROJECT/installed ]]
}
case_no_manager() {
    fixture; TEST_MANAGER=none
    expect_failure dependency_package_manager_missing
    [[ ! -s $PROJECT/calls ]]
}
case_apt() {
    fixture; TEST_MISSING='curl jq gpg flock setsid timeout sha256sum cmp unzip'
    local output args
    output=$(_bootstrap_install_dependencies)
    [[ -z $output && $(<"$PROJECT/calls") == $'consent\napt-get update\napt-get install' ]]
    args=$(<"$PROJECT/install.args")
    [[ $args == *$'install\ncurl\njq\ngnupg\nutil-linux\ncoreutils\ndiffutils\nunzip\nca-certificates' ]]
    [[ $args == *'AllowUnauthenticated=false'* && $args == *'AllowInsecureRepositories=false'* && $args == *'sourceparts=-'* ]]
    [[ $(<"$PROJECT/tty") == *'Packages: curl jq gnupg util-linux coreutils diffutils unzip ca-certificates'* ]]
    local sources=("$TMP"/dependencies.*/sources.list)
    [[ $(<"${sources[0]}") == *'signed-by=/usr/share/keyrings/debian-archive-keyring.gpg trusted=no'* ]]
    [[ $(<"${sources[0]}") == *'https://deb.debian.org/debian bookworm main'* ]]
}
case_sudo() {
    fixture; TEST_ROOT=no
    _bootstrap_install_dependencies
    [[ $(<"$PROJECT/calls") == $'consent\nsudo\napt-get update\nsudo\napt-get install' ]]
}
case_no_sudo() {
    fixture; TEST_ROOT=no TEST_SUDO=no
    expect_failure dependency_sudo_required
    [[ ! -s $PROJECT/calls ]]
}
case_install_failure() {
    fixture; TEST_FAIL=install
    expect_failure dependency_install_failed_reconcile_before_retry
    [[ $(<"$PROJECT/calls") == $'consent\napt-get update\napt-get install' && ! -e $PROJECT/installed ]]
    local logs=("$TMP"/dependencies.*/install.log)
    [[ $(<"${logs[0]}") == SYNTHETIC_PRIVATE_INSTALLER_OUTPUT ]]
}
case_update_failure() {
    fixture; TEST_FAIL=update
    expect_failure dependency_install_failed_reconcile_before_retry
    [[ $(<"$PROJECT/calls") == $'consent\napt-get update' && ! -e $PROJECT/install.args ]]
}
case_postcheck() {
    fixture; TEST_REPAIR=no
    expect_failure missing_dependency_jq
}
case_ca_only() {
    fixture; TEST_MISSING='' TEST_CA=no
    _bootstrap_install_dependencies
    [[ $(<"$PROJECT/install.args") == *$'install\nca-certificates' ]]
    local sources=("$TMP"/dependencies.*/sources.list)
    [[ $(<"${sources[0]}") == *'http://deb.debian.org/debian'* ]]
}
case_ca_postcheck() {
    fixture; TEST_CA=no TEST_CA_REPAIR=no
    expect_failure dependency_ca_bundle_missing_after_install
}
case_dnf() {
    fixture; TEST_DISTRO=fedora TEST_MANAGER=dnf TEST_MISSING='gpg flock setsid'
    _bootstrap_install_dependencies
    local args
    args=$(<"$PROJECT/install.args")
    [[ $(<"$PROJECT/calls") == $'consent\ndnf install' ]]
    [[ $args == *$'install\ngnupg2\nutil-linux' && $args == *'--disablerepo=*'* && $args == *'--enablerepo=fedora'* && $args == *'--enablerepo=updates'* && $args == *'--setopt=fedora.gpgcheck=1'* ]]
}
case_yum() {
    fixture; TEST_DISTRO=rocky TEST_MANAGER=yum
    _bootstrap_install_dependencies
    [[ $(<"$PROJECT/calls") == $'consent\nyum install' ]]
    [[ $(<"$PROJECT/install.args") == *'--enablerepo=baseos'* && $(<"$PROJECT/install.args") == *'--enablerepo=appstream'* ]]
}
case_rhel() {
    fixture; TEST_DISTRO=rhel TEST_MANAGER=dnf
    _bootstrap_install_dependencies
    [[ $(<"$PROJECT/install.args") == *'--enablerepo=rhel-9-for-x86_64-baseos-rpms'* ]]
}
case_ubuntu() {
    fixture; TEST_DISTRO=ubuntu TEST_CODENAME=noble
    _bootstrap_install_dependencies
    local sources=("$TMP"/dependencies.*/sources.list)
    [[ $(<"${sources[0]}") == *'https://archive.ubuntu.com/ubuntu noble main universe'* ]]
    [[ $(<"${sources[0]}") == *'https://security.ubuntu.com/ubuntu noble-security main universe'* ]]
}
case_unsupported() {
    fixture; TEST_DISTRO=alpine
    expect_failure unsupported_dependency_distro
    [[ ! -s $PROJECT/calls ]]
}
case_nonlinux() {
    fixture; OSTYPE=darwin
    expect_failure linux_required
}
case_symlink() {
    fixture; rm -d "$TMP"; mkdir -m 700 "$PROJECT/elsewhere"; ln -s "$PROJECT/elsewhere" "$TMP"
    expect_failure unsafe_install_tmp
    [[ ! -e $PROJECT/install.args ]]
}
case_permissions() {
    fixture; chmod 777 "$TMP"
    expect_failure unsafe_install_tmp
}
case_parent_permissions() {
    fixture; chmod 777 "$PROJECT"
    expect_failure unsafe_dependency_install_parent
}
case_wrong_owner() {
    fixture
    stat() { if [[ $2 == %u ]]; then printf 999999; else printf 700; fi; }
    expect_failure unsafe_dependency_install_parent
}
case_tmp_wrong_owner() {
    fixture
    stat() {
        if [[ $2 == %u ]]; then
            if [[ ${@: -1} == "$TMP" ]]; then printf 999999; else printf '%s' "$EUID"; fi
        else printf 700; fi
    }
    expect_failure unsafe_install_tmp
}
case_new_tmp() {
    fixture; rm -d "$TMP"
    _bootstrap_install_dependencies
    [[ -d $TMP && ! -L $TMP ]]
}
case_keyring_missing() {
    fixture
    _bootstrap_deps_keyring_ready() { return 1; }
    expect_failure distro_archive_keyring_required
    [[ ! -s $PROJECT/calls ]]
}
case_bad_codename() {
    fixture; TEST_CODENAME='$(touch NOT_EXECUTED)'
    expect_failure unsupported_dependency_distro_release
    [[ ! -s $PROJECT/calls ]]
}
case_missing_staging() {
    fixture
    _bootstrap_deps_helper() { return 1; }
    expect_failure unsafe_dependency_install_parent
    [[ ! -e $PROJECT/install.args ]]
}
case_missing_coreutils() {
    fixture; TEST_MISSING='stat mktemp mkdir chmod mv rm cp dd env od tr mkfifo date sleep uname realpath sync'
    _bootstrap_install_dependencies
    [[ $(<"$PROJECT/install.args") == *$'install\ncoreutils' ]]
}
case_source_data() {
    fixture
    unset -f _bootstrap_deps_release
    source "$REPO/shell/install-deps.sh"
    printf '%s\n' 'ID="debian"' 'VERSION_CODENAME="$(touch NOT_EXECUTED)"' > "$PROJECT/os-release"
    local deps_id deps_codename
    _bootstrap_deps_release "$PROJECT/os-release"
    [[ $deps_id == debian && $deps_codename == '$(touch NOT_EXECUTED)' ]]
}
case_all_packages() {
    fixture; TEST_MISSING='curl jq gpg flock timeout setsid sha256sum sync realpath stat mktemp mkdir chmod mv rm cp dd env od tr grep cmp mkfifo date sleep uname unzip'
    _bootstrap_install_dependencies
    [[ $(<"$PROJECT/install.args") == *$'install\ncurl\njq\ngnupg\nutil-linux\ncoreutils\ngrep\ndiffutils\nunzip\nca-certificates' ]]
}
count=0
for test in noop denied no_manager apt sudo no_sudo install_failure update_failure postcheck ca_only ca_postcheck dnf yum rhel ubuntu unsupported nonlinux symlink permissions parent_permissions wrong_owner tmp_wrong_owner new_tmp keyring_missing bad_codename missing_staging missing_coreutils source_data all_packages; do
    ("case_$test")
    printf 'ok %s\n' "$test"
    count=$((count + 1))
done
printf '%s dependency installer tests passed (offline).\n' "$count"
