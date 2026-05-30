#!/usr/bin/env bash
# Cloud-init user_data: install Docker Engine + compose plugin on Ubuntu 26.04.
# Idempotent enough to re-run; exits non-zero on any failure so cloud-init logs
# surface the problem in /var/log/cloud-init-output.log.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Wait for any boot-time apt/dpkg locks to clear before touching the package db.
for _ in $(seq 1 30); do
  if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

apt-get update -y
apt-get install -y ca-certificates curl gnupg

# Docker's official apt repository and signing key.
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
echo \
  "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker

# Let the default ubuntu user drive docker without sudo (used by scp/deploy).
usermod -aG docker ubuntu

echo "user_data complete: docker $(docker --version)" > /var/log/user_data.done
