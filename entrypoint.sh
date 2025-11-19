#!/bin/bash

# Read USERNAME and REPO_NAME from environment
USERNAME=${USERNAME:-}
REPO_NAME=${REPO_NAME:-}

# Check if required environment variables are set
if [ -z "$USERNAME" ] || [ -z "$REPO_NAME" ]; then
    echo "Error: USERNAME and REPO_NAME environment variables must be set"
    exit 1
fi

# Clone the repository from GitHub
echo "Cloning https://github.com/${USERNAME}/${REPO_NAME}.git..."
git clone "https://github.com/${USERNAME}/${REPO_NAME}.git" --depth 1 /${REPO_NAME}

# Change into the cloned directory
cd /${REPO_NAME} 

# Disable IPv6 at runtime (in case sysctl didn't work)
sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true

# Run opencode serve
exec /root/.opencode/bin/opencode web --hostname :: --port 8080 --print-logs