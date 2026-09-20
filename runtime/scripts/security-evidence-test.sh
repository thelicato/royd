#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT HUP INT TERM

cat > "$tmp/docker" <<'MOCK'
#!/bin/sh
set -eu
case "$1" in
  inspect)
    if [ "${2:-}" != --format ]; then exit 0; fi
    format=$3
    case "$format" in
      *HostConfig.Privileged*) printf '%s\n' false ;;
      *HostConfig.CapAdd*) printf '%s\n' 'SYS_ADMIN,SETUID,' ;;
      *HostConfig.CapDrop*) printf '%s\n' 'ALL,' ;;
      *HostConfig.SecurityOpt*) printf '%s\n' 'seccomp=default,' ;;
      *AppArmorProfile*) printf '%s\n' docker-default ;;
      *) exit 2 ;;
    esac
    ;;
  exec)
    cat <<'STATUS'
Name: init
CapInh: 0000000000000000
CapPrm: 0000000000280080
CapEff: 0000000000280080
CapBnd: 0000000000280080
CapAmb: 0000000000000000
NoNewPrivs: 0
Seccomp: 2
Seccomp_filters: 1
STATUS
    ;;
  *) exit 2 ;;
esac
MOCK
chmod +x "$tmp/docker"

PATH="$tmp:$PATH" "$script_dir/security-evidence.sh" royd-test experimental > "$tmp/evidence"
grep -Fq 'SECURITY_PROFILE_ID=experimental-v2-exact-caps' "$tmp/evidence"
grep -Eq '^SECURITY_PROFILE_SHA256=[0-9a-f]{64}$' "$tmp/evidence"
grep -Fq 'DOCKER_PRIVILEGED=false' "$tmp/evidence"
grep -Fq 'DOCKER_CAP_ADD=SYS_ADMIN,SETUID' "$tmp/evidence"
grep -Fq 'DOCKER_CAP_DROP=ALL' "$tmp/evidence"
grep -Fq 'APPARMOR_PROFILE=docker-default' "$tmp/evidence"
grep -Fq 'PID1_CAP_EFF=0000000000280080' "$tmp/evidence"
grep -Fq 'PID1_NO_NEW_PRIVS=0' "$tmp/evidence"
grep -Fq 'PID1_SECCOMP=2' "$tmp/evidence"

printf '%s\n' 'Runtime security evidence test passed'
