#!/usr/bin/env bash
# Source only. Caller supplies PROJECT, TMP, BOOTSTRAP_TTY, fail (must exit),
# and _bootstrap_confirm; call only in bootstrap after opening the local tty.

_bootstrap_deps_have() { command -v "$1" >/dev/null 2>&1; }
_bootstrap_deps_root() { (( EUID == 0 )); }

_bootstrap_deps_release() {
    local key value
    deps_id='' deps_codename=''
    # os-release is data, not shell code. Never source or eval it.
    while IFS='=' read -r key value || [[ -n $key ]]; do
        case $value in
            \"*\") value=${value:1:${#value}-2} ;;
            \'*\') value=${value:1:${#value}-2} ;;
        esac
        case $key in
            ID) deps_id=$value ;;
            VERSION_CODENAME) deps_codename=$value ;;
        esac
    done < "${1:-/etc/os-release}"
}

_bootstrap_deps_ca_ready() {
    local bundle
    for bundle in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem; do
        [[ ! -r $bundle || ! -s $bundle ]] || return 0
    done
    return 1
}

_bootstrap_deps_package() {
    case $1 in
        curl|jq|grep|unzip) printf '%s' "$1" ;;
        gpg) if [[ $deps_family == apt ]]; then printf gnupg; else printf gnupg2; fi ;;
        flock|setsid) printf util-linux ;;
        cmp) printf diffutils ;;
        *) printf coreutils ;;
    esac
}

_bootstrap_deps_helper() {
    local tool=$1; shift
    if _bootstrap_deps_have "$tool"; then "$tool" "$@"; return; fi
    # A damaged PATH need not prevent safe staging. BusyBox is only a staging
    # fallback, not a substitute for the GNU runtime dependencies being installed.
    local path
    for path in "/usr/bin/$tool" "/bin/$tool"; do
        if [[ -x $path ]]; then "$path" "$@"; return; fi
    done
    for path in /usr/bin/busybox /bin/busybox; do
        if [[ -x $path ]]; then "$path" "$tool" "$@"; return; fi
    done
    return 1
}

_bootstrap_deps_secure_dir() {
    local path=$1 private=${2:-no} owner mode
    [[ -d $path && ! -L $path ]] || return 1
    owner=$(_bootstrap_deps_helper stat -c %u -- "$path") || return 1
    mode=$(_bootstrap_deps_helper stat -c %a -- "$path") || return 1
    [[ $owner =~ ^[0-9]+$ && $mode =~ ^[0-7]{3,4}$ ]] || return 1
    if [[ $private == yes ]]; then
        [[ $owner == "$EUID" && $mode == 700 ]]
    else
        [[ ( $owner == 0 || $owner == "$EUID" ) && $((8#$mode & 022)) == 0 ]]
    fi
}

_bootstrap_deps_layout() {
    [[ ${PROJECT:-} == /* && $PROJECT != / && $PROJECT != *[[:cntrl:]]* && ${TMP:-} == "$PROJECT/tmp" ]] || fail invalid_project_tmp
    [[ $(cd -P -- "$PROJECT" 2>/dev/null && pwd -P) == "$PROJECT" ]] || fail invalid_project_root
    local parent=$PROJECT
    # Reject writable ancestors as well as symlinks: these paths are later
    # traversed by a privileged package manager. Shared /tmp roots are unsupported.
    while :; do
        _bootstrap_deps_secure_dir "$parent" || fail unsafe_dependency_install_parent
        [[ $parent != / ]] || break
        parent=${parent%/*}; parent=${parent:-/}
    done
    [[ ! -L $TMP ]] || fail unsafe_install_tmp
    if [[ ! -e $TMP ]]; then
        _bootstrap_deps_helper mkdir -m 700 -- "$TMP" || fail dependency_staging_tools_required
    fi
    _bootstrap_deps_secure_dir "$TMP" yes || fail unsafe_install_tmp
}

_bootstrap_deps_keyring_ready() { [[ -r $1 && -s $1 ]]; }

_bootstrap_deps_apt_sources() {
    local arch keyring mirror
    [[ $deps_codename =~ ^[a-z][a-z0-9-]*$ ]] || fail unsupported_dependency_distro_release
    case $deps_id in
        debian)
            keyring=/usr/share/keyrings/debian-archive-keyring.gpg
            mirror=https://deb.debian.org/debian
            ;;
        ubuntu)
            keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg
            arch=$(dpkg --print-architecture 2>/dev/null) || fail dependency_architecture_unknown
            case $arch in
                amd64|i386) mirror=https://archive.ubuntu.com/ubuntu ;;
                arm64|armhf|ppc64el|riscv64|s390x) mirror=https://ports.ubuntu.com/ubuntu-ports ;;
                *) fail unsupported_dependency_architecture ;;
            esac
            ;;
    esac
    _bootstrap_deps_keyring_ready "$keyring" || fail distro_archive_keyring_required
    # HTTP is needed when the CA bundle itself is missing. APT still verifies
    # signed Release metadata and package hashes against the distro keyring.
    if ! _bootstrap_deps_ca_ready; then mirror=${mirror/https:/http:}; fi
    local options="signed-by=$keyring trusted=no"
    printf 'deb [%s] %s %s main%s\n' "$options" "$mirror" "$deps_codename" "${deps_components:-}"
    printf 'deb [%s] %s %s-updates main%s\n' "$options" "$mirror" "$deps_codename" "${deps_components:-}"
    if [[ $deps_id == debian ]]; then
        printf 'deb [%s] %s://security.debian.org/debian-security %s-security main\n' "$options" "${mirror%%:*}" "$deps_codename"
    else
        if [[ $arch == amd64 || $arch == i386 ]]; then mirror=${mirror/archive.ubuntu.com/security.ubuntu.com}; fi
        printf 'deb [%s] %s %s-security main universe\n' "$options" "$mirror" "$deps_codename"
    fi
}

_bootstrap_deps_run() (
    export TMPDIR="$work/tmp" TMP="$work/tmp" TEMP="$work/tmp" XDG_CACHE_HOME="$work/cache"
    if _bootstrap_deps_root; then
        "$@"
    else
        # sudo is invoked only after the caller's interactive consent succeeded.
        sudo -- "TMPDIR=$TMPDIR" "TMP=$TMP" "TEMP=$TEMP" "XDG_CACHE_HOME=$XDG_CACHE_HOME" "$@"
    fi
)

_bootstrap_install_dependencies() (
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
        fail bash_4_4_required
    fi
    # OSTYPE is a Bash builtin variable, so missing uname can itself be repaired.
    [[ $OSTYPE == linux* ]] || fail linux_required
    local tools=(curl jq gpg flock timeout setsid sha256sum sync realpath stat mktemp mkdir chmod mv rm cp dd env od tr grep cmp mkfifo date sleep uname unzip)
    local missing=() packages=() tool package found existing
    for tool in "${tools[@]}"; do
        _bootstrap_deps_have "$tool" || missing+=("$tool")
    done
    local need_ca=no
    _bootstrap_deps_ca_ready || need_ca=yes
    if (( ${#missing[@]} == 0 )) && [[ $need_ca == no ]]; then return 0; fi

    local deps_id deps_codename deps_family manager deps_components=''
    _bootstrap_deps_release || fail unsupported_dependency_distro
    case $deps_id in
        debian|ubuntu)
            deps_family=apt manager=apt-get
            [[ $deps_id != ubuntu ]] || deps_components=' universe'
            ;;
        fedora|rhel|rocky|almalinux|centos)
            deps_family=rpm
            if _bootstrap_deps_have dnf; then manager=dnf
            elif _bootstrap_deps_have yum; then manager=yum
            else fail dependency_package_manager_missing; fi
            ;;
        *) fail unsupported_dependency_distro ;;
    esac
    _bootstrap_deps_have "$manager" || fail dependency_package_manager_missing
    for tool in "${missing[@]}"; do
        package=$(_bootstrap_deps_package "$tool")
        found=no
        for existing in "${packages[@]}"; do [[ $existing != "$package" ]] || found=yes; done
        [[ $found == yes ]] || packages+=("$package")
        [[ $tool != curl ]] || need_ca=yes
    done
    [[ $need_ca == no ]] || packages+=(ca-certificates)
    if ! _bootstrap_deps_root; then _bootstrap_deps_have sudo || fail dependency_sudo_required; fi

    local sources='' repos=() arch
    if [[ $deps_family == apt ]]; then
        sources=$(_bootstrap_deps_apt_sources) || exit 1
    else
        case $deps_id in
            fedora) repos=(fedora updates) ;;
            rocky|almalinux|centos) repos=(baseos appstream) ;;
            rhel)
                _bootstrap_deps_have rpm || fail dependency_rpm_required
                arch=$(rpm --eval '%{_arch}') || fail dependency_architecture_unknown
                local major
                major=$(rpm --eval '%{rhel}') || fail unsupported_dependency_distro_release
                [[ $arch =~ ^(x86_64|aarch64|ppc64le|s390x)$ && $major =~ ^(8|9|10)$ ]] || fail unsupported_dependency_distro_release
                repos=("rhel-$major-for-$arch-baseos-rpms" "rhel-$major-for-$arch-appstream-rpms")
                ;;
        esac
    fi
    printf '\nLinux prerequisite installation (%s / %s)\nMissing commands: %s\nPackages: %s\n' "$deps_id" "$manager" "${missing[*]:-(none; CA bundle missing)}" "${packages[*]}" >&"$BOOTSTRAP_TTY"
    if [[ $deps_family == apt ]]; then
        printf 'Only distro archive sources (signed by the installed distro keyring):\n%s\n' "$sources" >&"$BOOTSTRAP_TTY"
    else
        printf 'Only these configured distro repositories: %s (package signature verification required).\n' "${repos[*]}" >&"$BOOTSTRAP_TTY"
    fi
    if ! _bootstrap_deps_root; then
        printf 'After consent, sudo will run the package manager as root and may request your password.\n' >&"$BOOTSTRAP_TTY"
    fi
    printf 'Caches/logs: %s/dependencies.*. Package databases, locks and package scripts still change system paths. Dependencies may be installed/upgraded; no full-system upgrade.\n' "$TMP" >&"$BOOTSTRAP_TTY"
    _bootstrap_confirm 'Install these missing Linux prerequisites from the listed trusted distro repositories?' || fail bootstrap_consent_declined

    umask 077
    _bootstrap_deps_layout
    local work
    work=$(_bootstrap_deps_helper mktemp -d "$TMP/dependencies.XXXXXXXX") || fail dependency_staging_tools_required
    [[ $work == "$TMP/"* && ${work#"$TMP/"} != */* ]] || fail unsafe_install_tmp
    _bootstrap_deps_secure_dir "$work" yes || fail unsafe_install_tmp
    # Retain partial transactions for manual diagnosis; never retry implicitly.
    _bootstrap_deps_helper mkdir -m 700 -- "$work/tmp" "$work/cache" "$work/log" "$work/lists" "$work/state" || fail dependency_staging_tools_required
    printf 'Transaction logs (also retained if installation fails): %s\n' "$work" >&"$BOOTSTRAP_TTY"
    local args=() repo
    if [[ $deps_family == apt ]]; then
        printf '%s\n' "$sources" > "$work/sources.list" || fail dependency_staging_failed
        args=(-o "Dir::Etc::sourcelist=$work/sources.list" -o 'Dir::Etc::sourceparts=-'
            -o "Dir::Cache=$work/cache" -o "Dir::State::lists=$work/lists" -o "Dir::Log=$work/log"
            -o "DPkg::Options::=--log=$work/log/dpkg.log"
            -o APT::Get::AllowUnauthenticated=false -o Acquire::AllowInsecureRepositories=false
            -o Acquire::AllowDowngradeToInsecureRepositories=false -o Acquire::Check-Valid-Until=true
            -o Acquire::https::Verify-Peer=true -o Acquire::https::Verify-Host=true
            -o APT::Update::Error-Mode=any)
        _bootstrap_deps_run "$manager" "${args[@]}" update <&"$BOOTSTRAP_TTY" >"$work/update.log" 2>&1 || fail dependency_install_failed_reconcile_before_retry
        _bootstrap_deps_run "$manager" "${args[@]}" --yes --no-install-recommends install "${packages[@]}" <&"$BOOTSTRAP_TTY" >"$work/install.log" 2>&1 || fail dependency_install_failed_reconcile_before_retry
    else
        args=(--yes '--disablerepo=*' --setopt=gpgcheck=1 --setopt=localpkg_gpgcheck=1 --setopt=sslverify=True
            "--setopt=cachedir=$work/cache" "--setopt=persistdir=$work/state" "--setopt=logdir=$work/log"
            --setopt=keepcache=True --setopt=install_weak_deps=False)
        for repo in "${repos[@]}"; do args+=("--enablerepo=$repo" "--setopt=$repo.gpgcheck=1" "--setopt=$repo.sslverify=True" "--setopt=$repo.skip_if_unavailable=False"); done
        _bootstrap_deps_run "$manager" "${args[@]}" install "${packages[@]}" <&"$BOOTSTRAP_TTY" >"$work/install.log" 2>&1 || fail dependency_install_failed_reconcile_before_retry
    fi
    hash -r
    for tool in "${tools[@]}"; do
        _bootstrap_deps_have "$tool" || fail "missing_dependency_$tool"
    done
    _bootstrap_deps_ca_ready || fail dependency_ca_bundle_missing_after_install
    printf 'Linux prerequisites ready. Local transaction logs: %s\n' "$work" >&"$BOOTSTRAP_TTY"
)
