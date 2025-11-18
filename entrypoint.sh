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
git clone "https://github.com/${USERNAME}/${REPO_NAME}.git" /repo

# Change into the cloned directory
cd /repo

# Run opencode serve
exec /root/.opencode/bin/opencode web --hostname :: --port 8080