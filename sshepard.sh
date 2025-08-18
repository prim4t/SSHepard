#!/bin/bash
#
#   _____ _____ _    _                          _ 
#  / ____/ ____| |  | |                        | |
# | (___| (___ | |__| | ___ _ __   __ _ _ __ __| |
#  \___ \\___ \|  __  |/ _ \ '_ \ / _` | '__/ _` |
#  ____) |___) | |  | |  __/ |_) | (_| | | | (_| |
# |_____/_____/|_|  |_|\___| .__/ \__,_|_|  \__,_|
#                          | |                    
#                          |_|                    
#
# SSHepard - Lightweight Master-Node SSH Cluster Registrar

PORT=5000
LOGFILE="cluster_nodes.txt"
SSH_KEY="$HOME/.ssh/id_ed25519"
RATELIMIT=30
KNOWN_HOSTS="$HOME/.ssh/known_hosts"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# Ensure SSH server
if ! command -v sshd >/dev/null; then
    echo "Installing OpenSSH server..."
    if command -v apt >/dev/null; then
        sudo apt update && sudo apt install -y openssh-server
    elif command -v yum >/dev/null; then
        sudo yum install -y openssh-server
    elif command -v dnf >/dev/null; then
        sudo dnf install -y openssh-server
    else
        echo "Unsupported package manager. Install OpenSSH manually."
        exit 1
    fi
fi

sudo systemctl enable --now sshd

# Generate master key if missing
if [ ! -f "$SSH_KEY" ]; then
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "master@cluster"
fi

MASTER_PUBKEY=$(cat "${SSH_KEY}.pub")
MASTER_IP=$(hostname -I | awk '{print $1}')

# Output ready-to-use join command for nodes
JOIN_CMD="mkdir -p ~/.ssh && chmod 700 ~/.ssh && AUTH=~/.ssh/authorized_keys && grep -qxF \"$MASTER_PUBKEY\" \"\$AUTH\" 2>/dev/null || echo \"$MASTER_PUBKEY\" >> \"\$AUTH\" && chmod 600 \"\$AUTH\" && echo \"\$(whoami) \$(hostname -I | awk '{print \$1}')\" | nc -q 0 $MASTER_IP $PORT"
echo "=== COPY THIS COMMAND TO A NODE TO JOIN THE CLUSTER ==="
echo "$JOIN_CMD"
echo "======================================================"

# Listen for joins
echo "Master listening on TCP port $PORT..."
declare -A last_join
while true; do
    DATA=$(nc -l -p "$PORT" -q 1)
    [ -z "$DATA" ] && continue

    HOST=$(echo "$DATA" | awk '{print $1}')
    IP=$(echo "$DATA" | awk '{print $2}')

    # Sanitize
    [[ ! "$HOST" =~ ^[a-zA-Z0-9._-]+$ ]] && continue
    [[ ! "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && continue

    # Rate limit
    NOW=$(date +%s)
    if [[ -n "${last_join[$IP]}" ]] && (( NOW - last_join[$IP] < RATELIMIT )); then
        echo "Rate limit: ignoring $IP"
        continue
    fi
    last_join[$IP]=$NOW

    # Add to log if new
    if ! grep -q "^$HOST@$IP\$" "$LOGFILE" 2>/dev/null; then
        echo "$HOST@$IP" >> "$LOGFILE"
        echo "New node registered: $HOST $IP"
        # Add ED25519 key only to known_hosts
        if ! ssh-keygen -F "$IP" -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
            ssh-keyscan -t ed25519 -T 5 "$IP" >> "$KNOWN_HOSTS" 2>/dev/null && \
            echo "Added $HOST ($IP) ED25519 key to known_hosts"
        fi
    else
        echo "Duplicate join ignored: $HOST $IP"
    fi
done

