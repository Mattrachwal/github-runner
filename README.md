# GitHub Runner Setup

Automated setup for ephemeral, secure GitHub Actions runners with Docker-in-Docker support.

## Features

- ✅ Ephemeral runners (auto-cleanup after job completion)
- ✅ Docker-in-Docker support
- ✅ Security hardening (firewall, fail2ban, seccomp)
- ✅ Resource limits per runner
- ✅ Automatic runner registration
- ✅ Systemd service management
- ✅ Multi-runner support

## Prerequisites

- Fresh Debian/Ubuntu server (tested on Ubuntu 22.04)
- Root access
- GitHub Personal Access Token with `repo` and `admin:org` scopes

## Installation

1. Clone the repository:

```bash
git clone <your-repo-url> github-runner-setup
cd github-runner-setup
```

2. Copy and configure the config file:

```bash
cp config.yml.example config.yml
nano config.yml  # Edit with your settings
```

3. Run the installation script:

```bash
sudo bash install.sh
```

## Configuration

Edit `config.yml` to configure:

- GitHub organization and token
- Number of concurrent runners
- Resource limits (CPU, memory)
- Security settings
- Runner labels

## Management

### Check runner status:

```bash
sudo systemctl status github-runner-manager
docker ps
```

### Restart runners:

```bash
sudo systemctl restart github-runner-manager
```

### View logs:

```bash
sudo journalctl -u github-runner-manager -f
docker logs <container-name>
```

### Stop runners:

```bash
sudo systemctl stop github-runner-manager
```

### Clean up everything:

```bash
sudo bash scripts/cleanup.sh
```

## Security Features

- Non-root runner user
- Docker socket mounting with limited permissions
- Seccomp and AppArmor profiles
- Network isolation
- Resource limits
- Automatic security updates
- Firewall configuration
- Fail2ban for brute force protection

## Troubleshooting

### Runner not registering:

- Check GitHub token permissions
- Verify organization name
- Check logs: `sudo journalctl -u github-runner-manager -f`

### Docker permission issues:

- Ensure runner user is in docker group
- Restart Docker service: `sudo systemctl restart docker`

### Runner not starting:

- Check Docker is running: `sudo systemctl status docker`
- Verify network exists: `docker network ls`
- Check compose file: `docker-compose -f /home/github-runner/docker/docker-compose.yml config`

## License

MIT
