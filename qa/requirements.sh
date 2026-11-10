#!/bin/bash
# Checks this machine for everything ./prepare.sh needs, on any Linux
# distribution.
#
#   ./requirements.sh local|aws           # check only, changes nothing
#   ./requirements.sh local|aws --fix     # also fix the "todo" items
#
# It checks everything first. Anything it must not change on your system
# (FAIL: distribution packages, docker, ports in use, firewall, ...) stops it
# before it changes anything, even with --fix, and it tells you what to do.
# Only the "todo" items are fixed, and only with --fix:
#   - the release binaries of tofu, kubectl, helm (and k3d for local) that
#     are missing: downloaded, checksum-verified, into ~/.local/bin (or
#     $QA_BIN_DIR). No package manager, no sudo.
#   - qa/VERSION and qa/<env>/terraform.tfvars: copied from their .example.
#   - local, with sudo: the inotify limits, raised now and on every boot
#     (/etc/sysctl.d/90-fleet-qa.conf, a new file; nothing existing is edited).
# It never touches firewalls or installs distribution packages.
#
# Versions it installs (override with e.g. TOFU_VERSION=1.10.7):
TOFU_VERSION="${TOFU_VERSION:-1.13.9}"
K3D_VERSION="${K3D_VERSION:-5.9.0}"
HELM_VERSION="${HELM_VERSION:-4.3.1}"
KUBECTL_VERSION="${KUBECTL_VERSION:-1.32.13}" # same minor as distro_version in terraform.tfvars.example
set -uo pipefail
env="${1:-}" fix=""
[[ "$env" == local || "$env" == aws ]] || { echo "usage: ./requirements.sh local|aws [--fix]" >&2; exit 1; }
[[ "${2:-}" == --fix ]] && fix=1
[[ -n "${2:-}" && -z "$fix" ]] && { echo "usage: ./requirements.sh local|aws [--fix]" >&2; exit 1; }
qa="$(cd "$(dirname "$0")" && pwd)"
bin_dir="${QA_BIN_DIR:-$HOME/.local/bin}"
user_path="$PATH"
# sbin is not on a normal user's PATH on some distributions (sysctl, ip, ufw, ...)
export PATH="$PATH:$bin_dir:/usr/local/sbin:/usr/sbin:/sbin"

# Colors only on a terminal (and not with NO_COLOR set).
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  red=$'\e[1;31m' yellow=$'\e[1;33m' green=$'\e[32m' bold=$'\e[1m' dim=$'\e[2m' off=$'\e[0m'
else
  red="" yellow="" green="" bold="" dim="" off=""
fi
# Every FAIL and todo is also kept, with its hints, for the summary at the end.
failed=0 fixes=() fail_list=() todo_list=() last=""
ok() { echo "  ${green}ok${off}    $*"; last=""; }
bad() { echo "  ${red}FAIL${off}  ${red}$*${off}"; failed=$((failed + 1)); fail_list+=("$*"); last=fail; }
warn() { echo "  ${yellow}warn${off}  $*"; last=""; }
todo() { # todo <message> <fix command>: fixable with --fix
  echo "  ${yellow}todo${off}  ${yellow}$1${off}"; fixes+=("$2"); todo_list+=("$1"); last=todo
}
did() { echo "  ${green}fixed${off} $*"; last=""; }
hint() { # advice for the FAIL or todo just above
  echo "        ${dim}$*${off}"
  case "$last" in
    fail) fail_list[-1]+=$'\n'"$*" ;;
    todo) todo_list[-1]+=$'\n'"$*" ;;
  esac
}
summary() { # summary <title> <color> <items...>
  local title=$1 color=$2 item line n=0; shift 2
  (( $# )) || return 0
  echo; echo "${color}${title}${off}"
  for item in "$@"; do
    n=$((n + 1)); line=1
    while IFS= read -r l; do
      if (( line )); then echo "  ${color}$n. $l${off}"; line=0; else echo "     $l"; fi
    done <<<"$item"
  done
}
as_root() { if (( EUID == 0 )); then "$@"; else sudo "$@"; fi; }

echo "=== Platform"
[[ "$(uname -s)" == Linux ]] || { bad "Linux needed, this is $(uname -s)"; exit 1; }
case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) bad "unsupported CPU $(uname -m) (amd64 or arm64)"; exit 1 ;;
esac
ok "Linux $arch"

echo "=== Basic tools (from your distribution)"
pkg_manager=""
for pm in apt-get dnf zypper pacman apk; do command -v "$pm" >/dev/null && { pkg_manager=$pm; break; }; done
base_tools=(git curl jq envsubst zsh tar sha256sum awk sed base64 shuf)
[[ "$env" == local ]] && base_tools+=(docker)
[[ "$env" == aws ]] && base_tools+=(ssh aws)
missing_pkgs=()
for t in "${base_tools[@]}"; do
  if command -v "$t" >/dev/null; then ok "$t"; continue; fi
  bad "$t not found"
  case "$t:$pkg_manager" in
    envsubst:apt-get) missing_pkgs+=(gettext-base) ;;
    envsubst:zypper) missing_pkgs+=(gettext-runtime) ;;
    envsubst:apk) missing_pkgs+=(gettext-envsubst) ;;
    envsubst:*) missing_pkgs+=(gettext) ;;
    tar:* | sha256sum:* | awk:* | sed:* | base64:* | shuf:*) missing_pkgs+=(coreutils tar gawk sed) ;;
    ssh:apt-get) missing_pkgs+=(openssh-client) ;;
    ssh:pacman) missing_pkgs+=(openssh) ;;
    ssh:*) missing_pkgs+=(openssh-clients) ;;
    docker:*) hint "Docker Engine: https://docs.docker.com/engine/install/ (or your distribution's docker/moby package)" ;;
    aws:*) hint "AWS CLI v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" ;;
    *) missing_pkgs+=("$t") ;;
  esac
done
if (( ${#missing_pkgs[@]} )); then
  mapfile -t missing_pkgs < <(printf '%s\n' "${missing_pkgs[@]}" | sort -u)
  case "$pkg_manager" in
    apt-get) hint "install with: sudo apt-get install -y ${missing_pkgs[*]}" ;;
    dnf) hint "install with: sudo dnf install -y ${missing_pkgs[*]}" ;;
    zypper) hint "install with: sudo zypper install -y ${missing_pkgs[*]}" ;;
    pacman) hint "install with: sudo pacman -S --needed ${missing_pkgs[*]}" ;;
    apk) hint "install with: sudo apk add ${missing_pkgs[*]}" ;;
    *) hint "install these packages: ${missing_pkgs[*]}" ;;
  esac
fi

if [[ "$env" == local ]] && command -v docker >/dev/null; then
  if docker info >/dev/null 2>&1; then
    ok "docker daemon reachable as $(id -un)"
  else
    bad "cannot talk to the docker daemon as $(id -un)"
    hint "start it (e.g. sudo systemctl enable --now docker) and add yourself to the docker group:"
    hint "sudo usermod -aG docker $(id -un)   # then log out and in again"
  fi
fi

echo "=== Release binaries (into $bin_dir with --fix)"
fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }
install_bin() { # install_bin <name>: download, verify and install a pinned release
  local t tmp
  tmp=$(mktemp -d) || return 1
  t=$1
  (
    set -e
    cd "$tmp"
    case "$t" in
      tofu)
        f="tofu_${TOFU_VERSION}_linux_${arch}.tar.gz"
        u="https://github.com/opentofu/opentofu/releases/download/v$TOFU_VERSION"
        fetch "$u/$f" "$f"
        fetch "$u/tofu_${TOFU_VERSION}_SHA256SUMS" sums
        grep " $f\$" sums | sha256sum -c --quiet
        tar -xzf "$f" tofu ;;
      k3d)
        f="k3d-linux-$arch"
        u="https://github.com/k3d-io/k3d/releases/download/v$K3D_VERSION"
        fetch "$u/$f" "$f"
        fetch "$u/checksums.txt" sums
        echo "$(awk -v f="_dist/$f" '$2 == f {print $1}' sums)  $f" | sha256sum -c --quiet
        mv "$f" k3d ;;
      kubectl)
        u="https://dl.k8s.io/release/v$KUBECTL_VERSION/bin/linux/$arch/kubectl"
        fetch "$u" kubectl
        fetch "$u.sha256" sum
        echo "$(cat sum)  kubectl" | sha256sum -c --quiet ;;
      helm)
        f="helm-v${HELM_VERSION}-linux-$arch.tar.gz"
        fetch "https://get.helm.sh/$f" "$f"
        fetch "https://get.helm.sh/$f.sha256sum" sum
        sha256sum -c --quiet sum
        tar -xzf "$f" --strip-components=1 "linux-$arch/helm" ;;
    esac
    mkdir -p "$bin_dir"
    install -m 0755 "$t" "$bin_dir/$t"
  )
  local rc=$?
  rm -rf "$tmp"
  return $rc
}
bins=(tofu kubectl helm)
[[ "$env" == local ]] && bins+=(k3d)
for t in "${bins[@]}"; do
  if ! command -v "$t" >/dev/null; then
    todo "$t not found (--fix installs ${t} into $bin_dir)" "fix_bin $t"; continue
  fi
  case "$t" in
    tofu)
      v=$(tofu version -json 2>/dev/null | jq -r .terraform_version)
      if [[ "$(printf '%s\n' 1.8.1 "$v" | sort -V | head -1)" == 1.8.1 ]]; then ok "tofu $v ($(command -v tofu))"
      else bad "tofu $v ($(command -v tofu)) is too old, >= 1.8.1 needed: upgrade it, or remove it and run --fix"; fi ;;
    kubectl)
      v=$(kubectl version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion)
      ok "kubectl $v ($(command -v kubectl))" ;;
    helm) ok "helm $(helm version --short 2>/dev/null) ($(command -v helm))" ;;
    k3d) ok "k3d $(k3d version 2>/dev/null | awk 'NR==1 {print $3}') ($(command -v k3d))" ;;
  esac
done
fix_bin() {
  if install_bin "$1"; then did "$1 installed in $bin_dir"; else bad "$1: download or checksum failed"; fi
  if [[ ":$user_path:" != *":$bin_dir:"* ]]; then
    warn "$bin_dir is not on your PATH; add to your shell profile: export PATH=\"$bin_dir:\$PATH\""
  fi
}

echo "=== Configuration files"
cfg() { # cfg <file>: must exist; --fix copies <file>.example
  local f="$1" ex="$1.example"
  if [[ -f "$f" ]]; then ok "${f#$qa/}"
  else todo "${f#$qa/} missing (--fix copies ${ex#$qa/}, review it after)" "fix_cfg $f"; fi
}
fix_cfg() { [[ -e "$1" ]] || cp "$1.example" "$1" && did "${1#$qa/} created from ${1#$qa/}.example (review it)"; }
cfg "$qa/VERSION"
cfg "$qa/$env/terraform.tfvars"
[[ -f "$qa/VERSION" ]] && ok "Fleet version to install: $(cat "$qa/VERSION")"

if [[ "$env" == local ]]; then
tfvars="$qa/local/terraform.tfvars"
[[ -f "$tfvars" ]] || tfvars="$qa/local/terraform.tfvars.example"
tfvar() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\" #]*\).*/\1/p" "$tfvars" | head -1; }
project=$(tfvar project_name); project=${project:-st-local}
first_api=$(tfvar first_kubernetes_api_port); first_api=${first_api:-6445}
first_http=$(tfvar first_app_http_port); first_http=${first_http:-8080}
first_https=$(tfvar first_app_https_port); first_https=${first_https:-8443}
downstream=$(awk -F= '/^[[:space:]]*cluster_count/ {gsub(/[^0-9]/, "", $2); n += $2} END {print n + 0}' "$tfvars")
clusters=$((1 + downstream))

echo "=== Kernel limits ($clusters clusters)"
inotify_instances=8192 inotify_watches=524288
cur_inst=$(cat /proc/sys/fs/inotify/max_user_instances)
cur_watch=$(cat /proc/sys/fs/inotify/max_user_watches)
# 1280 instances were enough for a 10-cluster run; the kernel default (128) is not.
if (( cur_inst >= 1280 )); then
  ok "fs.inotify.max_user_instances=$cur_inst"
else
  todo "fs.inotify.max_user_instances=$cur_inst is too low, >= 1280 needed (--fix sets $inotify_instances, with sudo)" fix_inotify
fi
if (( cur_watch >= inotify_watches )); then
  ok "fs.inotify.max_user_watches=$cur_watch"
else
  warn "fs.inotify.max_user_watches=$cur_watch, $inotify_watches recommended for many clusters"
fi
fix_inotify() {
  # /proc/sys and /etc/sysctl.d work the same on every distribution, with or
  # without the sysctl binary on PATH. Only raises, never lowers.
  local inst=$inotify_instances watch=$inotify_watches
  (( cur_inst > inst )) && inst=$cur_inst
  (( cur_watch > watch )) && watch=$cur_watch
  if [[ -e /etc/sysctl.d/90-fleet-qa.conf ]]; then
    bad "/etc/sysctl.d/90-fleet-qa.conf already exists, not overwriting it; check its values"; return
  fi
  if printf 'fs.inotify.max_user_instances = %s\nfs.inotify.max_user_watches = %s\n' "$inst" "$watch" \
      | as_root tee /etc/sysctl.d/90-fleet-qa.conf >/dev/null \
    && echo "$inst" | as_root tee /proc/sys/fs/inotify/max_user_instances >/dev/null \
    && echo "$watch" | as_root tee /proc/sys/fs/inotify/max_user_watches >/dev/null; then
    did "inotify limits set to $inst instances / $watch watches (kept on reboot by /etc/sysctl.d/90-fleet-qa.conf)"
  else
    bad "could not raise the inotify limits (sudo failed)"
  fi
}
mem_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
if (( mem_kb / 1024 / 1024 >= clusters )); then ok "$((mem_kb / 1024 / 1024)) GiB RAM available (about 1 GiB per cluster)"
else warn "only $((mem_kb / 1024 / 1024)) GiB RAM available, $clusters clusters want about $clusters GiB"; fi

echo "=== Host ports"
# Listening TCP ports, from /proc (no ss/netstat needed).
listening=" $(awk '$4 == "0A" {split($2, a, ":"); print a[2]}' /proc/net/tcp /proc/net/tcp6 2>/dev/null \
  | sort -u | while read -r h; do printf '%d ' "0x$h"; done)"
# Ports held by this setup's own containers are fine (a re-run).
own=" "
if docker info >/dev/null 2>&1; then
  while read -r spec; do
    if [[ "$spec" == *-* ]]; then own+="$(seq -s ' ' "${spec%-*}" "${spec#*-}") "; else own+="$spec "; fi
  done < <(docker ps --format '{{.Names}} {{.Ports}}' | awk -v p="k3d-$project-" 'index($1, p) == 1 || $1 == "gitea"' \
    | grep -oE ':[0-9]+(-[0-9]+)?->' | tr -d ':>' | sed 's/-$//')
fi
check_ports() { # check_ports <what> <first> <count>
  local busy=() p
  for ((p = $2; p < $2 + $3; p++)); do
    [[ "$listening" == *" $p "* && "$own" != *" $p "* ]] && busy+=("$p")
  done
  local range=$2; (( $3 > 1 )) && range="$2-$(($2 + $3 - 1))"
  if (( ${#busy[@]} == 0 )); then ok "$1: $range free (or held by this setup)"; return; fi
  bad "$1: port(s) ${busy[*]} already in use"
  local users
  users=$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | while read -r n ports; do
    for b in "${busy[@]}"; do
      grep -qE ":$b->|:[0-9]+-[0-9]+->" <<<"$ports" || continue
      grep -oE ":[0-9]+(-[0-9]+)?->" <<<"$ports" | tr -d ':>' | sed 's/-$//' | while read -r s; do
        lo=${s%-*} hi=${s#*-}; (( b >= lo && b <= hi )) && echo "$n"
      done
    done
  done | sort -u | tr '\n' ' ')
  [[ -n "$users" ]] && hint "held by container(s): $users"
  hint "stop what holds them, or move ${4:-the range} in local/terraform.tfvars"
  [[ -n "${5:-}" ]] && hint "$5"
}
check_ports "Kubernetes API" "$first_api" "$clusters" first_kubernetes_api_port
check_ports "app HTTP" "$first_http" "$clusters" first_app_http_port \
  "if you move it, also export WEBHOOK_PORT=<new port> before ./prepare.sh local (setup-gitea.sh assumes 8080)"
check_ports "app HTTPS" "$first_https" "$clusters" first_app_https_port
check_ports "registry pull proxies" 5001 3
check_ports "Gitea" 3000 1

echo "=== Network: clusters <-> this machine"
# What the setup needs, tested with two throwaway containers:
#  - pods (on the k3d docker network) reach Gitea (published on the host)
#    through the network's gateway IP
#  - Gitea (default bridge) reaches the cluster's ingress (published on the
#    host) through this machine's LAN IP, for the webhooks
# A host firewall is what usually blocks this; which one does not matter here.
host_lan_ip() {
  local ip
  ip=$(ip -4 -o route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')
  [[ -n "$ip" ]] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo "$ip"
}
net_test() { # prints the paths that fail, nothing if all work
  local id=qa-req-$$ gw port1 port2 lan
  docker network create "$id" >/dev/null || { echo "docker network create failed"; return; }
  gw=$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' "$id")
  srv='mkdir -p /w && echo ok >/w/index.html && exec httpd -f -p 80 -h /w'
  docker run -d --rm --name "$id-gitea" -p 80 busybox sh -c "$srv" >/dev/null
  docker run -d --rm --name "$id-ingress" --network "$id" -p 80 busybox sh -c "$srv" >/dev/null
  port1=$(docker port "$id-gitea" 80/tcp | head -1 | sed 's/.*://')
  port2=$(docker port "$id-ingress" 80/tcp | head -1 | sed 's/.*://')
  lan=$(host_lan_ip)
  docker run --rm --network "$id" busybox wget -q -T 5 -O /dev/null "http://$gw:$port1/" 2>/dev/null \
    || echo "  cluster network ($(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$id")) -> $gw:$port1 (how pods reach Gitea)"
  docker run --rm busybox wget -q -T 5 -O /dev/null "http://$lan:$port2/" 2>/dev/null \
    || echo "  default bridge -> $lan:$port2 (how Gitea's webhooks reach the cluster)"
  docker rm -f "$id-gitea" "$id-ingress" >/dev/null 2>&1
  docker network rm "$id" >/dev/null 2>&1
}
active_firewall() { # only to tailor the advice; nothing is changed
  if command -v ufw >/dev/null && grep -qs '^ENABLED=yes' /etc/ufw/ufw.conf; then echo ufw
  elif command -v firewall-cmd >/dev/null && { systemctl is-active -q firewalld 2>/dev/null || pgrep -f '[f]irewalld' >/dev/null; }; then echo firewalld
  elif command -v nft >/dev/null || command -v iptables >/dev/null; then echo "nftables/iptables"
  fi
}
if ! docker info >/dev/null 2>&1; then
  bad "not tested: docker is not usable"
elif ! docker image inspect busybox >/dev/null 2>&1 && ! docker pull -q busybox >/dev/null 2>&1; then
  bad "not tested: cannot pull the busybox image for the test"
else
  fw=$(active_firewall)
  blocked=$(net_test)
  if [[ -z "$blocked" ]]; then
    ok "containers on another docker network reach published ports on this machine"
  else
    bad "clusters cannot reach this machine, most likely the host firewall${fw:+ ($fw)} blocks them"
    while IFS= read -r l; do hint "blocked: ${l#  }"; done <<<"$blocked"
    hint "This script does not change firewalls. Allow incoming traffic from docker's networks"
    hint "(172.16.0.0/12 by default) in yours, then run this again. For example:"
    case "$fw" in
      ufw) hint "  sudo ufw allow from 172.16.0.0/12" ;;
      firewalld) hint "  sudo firewall-cmd --permanent --zone=trusted --add-source=172.16.0.0/12 && sudo firewall-cmd --reload" ;;
      *) hint "  sudo iptables -I INPUT -s 172.16.0.0/12 -j ACCEPT   (not persistent)" ;;
    esac
  fi
fi
fi # local

summary "=== $failed problem(s) to solve by hand (FAIL)" "$red" "${fail_list[@]}"
summary "=== ${#fixes[@]} item(s) --fix can do (todo)" "$yellow" "${todo_list[@]}"
echo
if (( failed )); then
  echo "${bold}${red}Not ready.${off} Solve the FAIL items, then run this again. Nothing was changed${fix:+, not even the todo items}."
  exit 1
fi
if (( ${#fixes[@]} == 0 )); then
  [[ "$env" == local ]] && echo "${bold}${green}All set:${off} ./prepare.sh local"
  [[ "$env" == aws ]] && echo "${bold}${green}All set.${off} Still needed before ./prepare.sh aws: aws sso login --profile <aws_profile in aws/terraform.tfvars>"
  exit 0
fi
if [[ -z "$fix" ]]; then
  echo "${bold}${yellow}Not ready yet.${off} Run ./requirements.sh $env --fix to do the todo items."
  exit 1
fi
echo "=== Fixing"
for f in "${fixes[@]}"; do eval "$f"; done
echo
(( failed )) && { echo "${bold}${red}Some fixes failed:${off}"; summary "=== failed" "$red" "${fail_list[@]}"; exit 1; }
echo "Done. Run ./requirements.sh $env again to confirm."
