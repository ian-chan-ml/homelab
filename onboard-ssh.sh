#!/usr/bin/env bash
# onboard-ssh.sh — Seed ~/.ssh/authorized_keys from this repo's authorized_keys file
#
# Public keys aren't secret, so this pulls straight from this public repo —
# no auth token needed, works as a true one-line curl | bash.
#
# Adding a new trusted key: append it to authorized_keys in this repo,
# then re-run the one-liner below on any machine.
#
# Usage (on any new machine):
#   curl -fsSL https://raw.githubusercontent.com/ian-cq/homelab/main/onboard-ssh.sh | bash
#
# Existing keys are never duplicated.

set -euo pipefail

KEYS_URL="${KEYS_URL:-https://raw.githubusercontent.com/ian-cq/homelab/main/authorized_keys}"

mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

curl -fsSL "$KEYS_URL" | while read -r line; do
  [ -z "$line" ] && continue
  grep -qxF "$line" ~/.ssh/authorized_keys || echo "$line" >> ~/.ssh/authorized_keys
done

echo "authorized_keys updated ($(wc -l < ~/.ssh/authorized_keys) keys)."
