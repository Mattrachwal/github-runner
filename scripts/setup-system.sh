  #!/bin/bash
set -euo pipefail

CONFIG_FILE="${SCRIPT_DIR}/config.yml"

# System hardening
log "Applying system hardening..."

# Update system
apt-get update && apt-get upgrade -y

# Configure sysctl for security
cat > /etc/sysctl.d/99-runner-security.conf <<EOF
# IP Spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# Ignore send redirects
net.ipv4.conf.all.send_redirects = 0

# Disable source packet routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Log Martians
net.ipv4.conf.all.log_martians = 1

# Ignore ICMP ping requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignore Directed pings
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Enable TCP/IP SYN cookies
net.ipv4.tcp_syncookies = 1

# Disable IPv6 if not needed
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

sysctl -p /etc/sysctl.d/99-runner-security.conf

# Configure firewall if enabled
if [[ $(yq eval '.security.enable_firewall' "$CONFIG_FILE") == "true" ]]; then
    log "Configuring firewall..."
    ufw --force enable
    ufw default deny incoming
    ufw default allow outgoing
    
    # Allow SSH with restrictions
    SSH_IPS=$(yq eval '.security.ssh_allowed_ips' "$CONFIG_FILE")
    if [[ -n "$SSH_IPS" ]] && [[ "$SSH_IPS" != "null" ]]; then
        IFS=',' read -ra IPS <<< "$SSH_IPS"
        for ip in "${IPS[@]}"; do
            ufw allow from "$ip" to any port 22
        done
    else
        ufw allow 22/tcp
    fi
    
    # Allow Docker communication
    ufw allow 2376/tcp
    ufw allow 2377/tcp
    ufw allow 7946/tcp
    ufw allow 7946/udp
    ufw allow 4789/udp
    
    ufw --force reload
fi

# Configure fail2ban
log "Configuring fail2ban..."
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ssh
logpath = /var/log/auth.log
EOF

systemctl restart fail2ban

# Setup automatic security updates if enabled
if [[ $(yq eval '.security.auto_updates' "$CONFIG_FILE") == "true" ]]; then
    log "Configuring automatic security updates..."
    apt-get install -y unattended-upgrades
    dpkg-reconfigure -plow unattended-upgrades
fi