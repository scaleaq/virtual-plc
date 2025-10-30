#!/usr/bin/env bash
#
# Idempotent Docker + Docker Compose (plugin) installer for common Linux distros & WSL.
# Supports: Ubuntu/Debian, Raspbian, Kali, Linux Mint, Fedora, CentOS/RHEL 8+, Rocky/Alma,
# Amazon Linux 2, openSUSE (Leap/Tumbleweed), Alpine, Arch/Manjaro, WSL (Debian/Ubuntu based).
#
# Usage:
#   curl -fsSL https://example.com/install-docker.sh -o install-docker.sh
#   bash install-docker.sh
#
# After install: log out/in (or `newgrp docker`) to apply docker group membership.
set -euo pipefail

MIN_DOCKER_VERSION="24.0.0"

need_root() {
  if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      sudo -E bash "$0" "$@"
      exit $?
    else
      echo "Please run as root (no sudo available)." >&2
      exit 1
    fi
  fi
}

version_ge() {
  # returns 0 if $1 >= $2 (semantic-ish compare)
  # removes trailing + or ~ parts
  local A B
  A=$(echo "$1" | sed 's/[^0-9.].*$//')
  B=$(echo "$2" | sed 's/[^0-9.].*$//')
  dpkg --compare-versions "$A" ge "$B" 2>/dev/null || \
    { # fallback manual compare if dpkg not present
      [[ "$(printf '%s\n%s\n' "$B" "$A" | sort -V | tail -n1)" == "$A" ]]
    }
}

have_docker() {
  command -v docker >/dev/null 2>&1
}

docker_ok() {
  if ! have_docker; then return 1; fi
  local v
  v=$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)
  [[ -z "$v" ]] && return 1
  version_ge "$v" "$MIN_DOCKER_VERSION"
}

have_compose() {
  docker compose version >/dev/null 2>&1 || docker-compose version >/dev/null 2>&1
}

ensure_packages() {
  # deb/rpm convenience function
  local pkgs=("$@")
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${pkgs[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${pkgs[@]}"
  fi
}

install_debian_family() {
  ensure_packages ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  local codename
  codename=$(. /etc/os-release; echo "${VERSION_CODENAME:-}")
  if [[ -z "$codename" ]]; then
    codename=$(lsb_release -cs 2>/dev/null || echo "stable")
  fi
  echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(
  . /etc/os-release; echo "$ID"
) $codename stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_rhel_family() {
  ensure_packages curl ca-certificates gnupg
  if command -v dnf >/dev/null 2>&1; then
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || true
    dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || true
    yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  systemctl enable docker || true
}

install_amazon_linux() {
  ensure_packages curl ca-certificates
  amazon-linux-extras install docker -y || yum install -y docker
  # Compose plugin not in amazon-linux-extras; install manually below if missing
}

install_fedora() {
  dnf -y install dnf-plugins-core
  dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo || true
  dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable docker || true
}

install_suse() {
  zypper --non-interactive install curl ca-certificates gpg2
  local release
  release=$(. /etc/os-release; echo "$VERSION_ID")
  rpm --import https://download.docker.com/linux/sles/gpg || true
  cat >/etc/zypp/repos.d/docker.repo <<EOF
[docker-ce-stable]
name=Docker CE Stable - x86_64
baseurl=https://download.docker.com/linux/sles/$release/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/sles/gpg
EOF
  zypper --non-interactive refresh
  zypper --non-interactive install docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable docker || true
}

install_alpine() {
  apk update
  apk add --no-cache docker docker-cli-compose
  rc-update add docker default || true
}

install_arch() {
  pacman -Sy --noconfirm --needed docker docker-compose
  systemctl enable docker || true
}

install_compose_plugin_manually() {
  # Fallback for distros lacking docker compose plugin package
  if docker compose version >/dev/null 2>&1; then return; fi
  local target="/usr/lib/docker/cli-plugins/docker-compose"
  local url
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    armv7l) arch="armv7" ;;
    *) echo "Unsupported arch for manual compose plugin: $arch" >&2; return 1 ;;
  esac
  url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}"
  echo "Installing docker compose plugin from $url"
  curl -fsSL "$url" -o "$target"
  chmod +x "$target"
}

detect_wsl() {
  if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    return 0
  fi
  return 1
}

start_docker_service() {
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q docker.service; then
    systemctl start docker || true
  elif command -v service >/dev/null 2>&1; then
    service docker start || true
  fi
}

main() {
  need_root "$@"

  if docker_ok && have_compose; then
    echo "Docker (>= ${MIN_DOCKER_VERSION}) and Compose already installed."
  fi

  . /etc/os-release || { echo "Cannot read /etc/os-release"; exit 1; }
  ID_LIKE=${ID_LIKE:-}
  case "$ID" in
    ubuntu|debian|raspbian|kali|linuxmint) install_debian_family ;;
    fedora) install_fedora ;;
    centos|rhel|rocky|almalinux|ol) install_rhel_family ;;
    amzn) install_amazon_linux ;;
    opensuse*|sles) install_suse ;;
    alpine) install_alpine ;;
    arch|manjaro) install_arch ;;
    *)
      # fallback by ID_LIKE
      if echo "$ID_LIKE" | grep -qi 'debian'; then
        install_debian_family
      elif echo "$ID_LIKE" | grep -qiE 'rhel|fedora|centos'; then
        install_rhel_family
      elif echo "$ID_LIKE" | grep -qi 'suse'; then
        install_suse
      else
        echo "Unsupported distribution: $ID" >&2
        exit 1
      fi
      ;;
  esac

  # Start service where applicable
  start_docker_service

  # Add invoking user (if not root) to docker group
  local INVOKER
  INVOKER=${SUDO_USER:-${USER}}
  if ! getent group docker >/dev/null 2>&1; then
    groupadd docker
  fi
  if id -nG "$INVOKER" | grep -qw docker; then
    echo "User '$INVOKER' already in docker group."
  else
    usermod -aG docker "$INVOKER"
    echo "Added user '$INVOKER' to docker group."
  fi

  install_compose_plugin_manually || true

  if detect_wsl; then
    echo "Detected WSL environment."
    if [[ ! -f /etc/wsl.conf ]] || ! grep -q 'systemd=true' /etc/wsl.conf; then
      cat <<'WSLNOTE'
NOTE: If Docker daemon does not auto-start under WSL, either:
  - Enable systemd (WSL2 only). Add to /etc/wsl.conf:
      [boot]
      systemd=true
    Then run: wsl --shutdown (from Windows) and reopen.
  - Or start manually each session: sudo service docker start
WSLNOTE
    fi
  fi

  echo
  echo "Docker version: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'UNKNOWN')"
  if docker compose version >/dev/null 2>&1; then
    echo "Docker Compose (plugin): $(docker compose version | head -n1)"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "Docker Compose (standalone): $(docker-compose version | head -n1)"
  else
    echo "Docker Compose not found (unexpected)."
  fi
  echo
  echo "Idempotent install complete."
  echo "If this is your first install, open a new shell (or run: newgrp docker) to use docker without sudo."
}

main "$@"
