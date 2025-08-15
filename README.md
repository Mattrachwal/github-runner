# GitHub Actions Self-Hosted Runner Setup (Multi-Runner, Auto Install)

This repository provides an **easy one-command installer** for secure, systemd-managed GitHub Actions self-hosted runners.  
It supports **multiple runners**, each with its own organization or repository scope, token, labels, and instance count.

---

## Features

- **One command setup** (`setup.sh`) — no manual dependency installs.
- Supports **multiple runners** with different scopes and tokens.
- **Automatic**:
  - Package installation (GitHub runner deps, jq, etc.)
  - Optional Docker Engine install (`WITH_DOCKER=1` flag)
  - User & directory creation
  - Systemd unit + security hardening
  - Runner registration and service start
- Configurable resource limits via systemd drop-in.
- Easy uninstall script.

---

## Requirements

- Debian / Ubuntu-based Linux
- Root access (`sudo`)
- A valid GitHub Actions **registration token** for each runner  
  ([GitHub docs: Adding self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners/adding-self-hosted-runners))

---

## Quick Start

1. **Clone this repository** to your server:

   ```bash
   git clone https://github.com/Mattrachwal/github-runner.git
   cd github-runner
   ```

2. **Edit `config.json`** in the repo root:

   ```json
   {
     "runners": [
       {
         "name": "mini1-shared",
         "scope_url": "https://github.com/your-org",
         "registration_token": "REPLACE_WITH_TOKEN",
         "labels": ["self-hosted", "linux", "x64", "mini-pc"],
         "instances": 5,
         "work_dir": "/var/lib/github-runner/mini1-shared"
       },
       {
         "name": "repo-special",
         "scope_url": "https://github.com/your-org/specific-repo",
         "registration_token": "REPLACE_WITH_ANOTHER_TOKEN",
         "labels": ["self-hosted", "linux", "special"],
         "instances": 1,
         "work_dir": "/var/lib/github-runner/repo-special"
       }
     ]
   }
   ```

   - `scope_url`: Can be an org (`https://github.com/org`) or repo (`https://github.com/org/repo`)
   - `instances`: Number of runner processes to spin up for this config
   - `labels`: Comma-separated labels your workflows can target

3. **Run setup**:

   Without Docker support:

   ```bash
   sudo ./scripts/setup.sh
   ```

   With Docker support:

   ```bash
   sudo WITH_DOCKER=1 ./scripts/setup.sh
   ```

   > This will:
   >
   > - Install all dependencies
   > - Optionally install Docker
   > - Copy your `config.json` to `/etc/github-runner/config.json`
   > - Register all runners
   > - Start and enable their systemd services

4. **Verify** runners in GitHub UI under:
   - **Org settings → Actions → Runners** (for org-scoped)
   - **Repo settings → Actions → Runners** (for repo-scoped)

---

## Scripts

| Script                          | Description                                                                      |
| ------------------------------- | -------------------------------------------------------------------------------- |
| `scripts/setup.sh`              | **One-command installer** — calls install, register, and harden.                 |
| `scripts/install.sh`            | Installs dependencies, creates user/dirs, copies config, sets up systemd.        |
| `scripts/register-from-json.sh` | Reads `/etc/github-runner/config.json`, registers each runner, enables services. |
| `scripts/harden-systemd.sh`     | Re-applies unit + override security settings and restarts runners.               |
| `scripts/update.sh`             | Notes for updating runner binaries.                                              |
| `scripts/uninstall.sh`          | Stops services, removes units/data/user.                                         |

---

## Stopping / Starting / Restarting Runners

Each runner instance is a systemd service named:

`github-runner@<runner-name>-<instance-number>.service`

### Restart one instance

sudo systemctl restart github-runner@mini1-shared-1.service

### Restart all instances

sudo systemctl list-units --type=service | grep github-runner@ | awk '{print $1}' | xargs -n1 sudo systemctl restart

## Uninstall

`sudo ./scripts/uninstall.sh`

This will:

- Stop & disable all runner services
- Remove systemd units
- Delete /opt/actions-runner and /var/lib/github-runner
- Remove the github-runner user

## Notes

- Security: The systemd unit applies a baseline of security hardening. Review config/systemd/github-runner@.service and adjust to your environment.

- Docker: If your workflows use Docker, pass WITH_DOCKER=1 when running setup.sh to install Docker Engine. Docker socket access is root-equivalent.

- Tokens: Registration tokens expire quickly (1 hour by default). Ensure you generate them right before running setup.

## ⚠️ Security Warnings

Self-hosted GitHub Actions runners **execute arbitrary code** from your workflows.  
This means that **anyone with permission to modify or approve workflows in your repository or organization can run commands on the machine hosting your runner**.

### Key Risks

1. **Workflow Trust** – If a malicious workflow is merged into your repository, it can:

   - Install backdoors or crypto-miners
   - Steal secrets or credentials
   - Modify or delete files on the host system

2. **Secrets Exposure** – Any secrets configured in GitHub Actions can be accessed by jobs that run on this runner.  
   Malicious jobs can print or exfiltrate them.

3. **Docker Access Equals Root** – If Docker is installed and accessible to the runner user:

   - Any job can mount the host filesystem
   - Any job can start privileged containers and escalate to full root access

4. **Network Access** – By default, runners can reach any host your network allows.

   - This could include databases, internal services, or other sensitive systems

5. **Persistent Services** – Long-lived runners keep their environment between jobs unless explicitly cleaned.  
   Residual files, logs, or build artifacts can leak sensitive data.

### Mitigation Recommendations

While this setup script **does not** implement these measures automatically, you should strongly consider:

- Restricting who can modify workflows (branch protection, required reviews)
- Limiting Actions to trusted sources (GitHub → Settings → Actions → General)
- Reducing `GITHUB_TOKEN` default permissions to **read-only**
- Running runners on **isolated hosts or VMs** separate from production systems
- Using ephemeral runners for untrusted workloads
- Keeping host software up to date and applying standard Linux hardening (SSH restrictions, firewall rules, sysctl tuning)

> **Bottom line:** If someone can change or approve workflows in your repo, they can control the machine running the runner. Treat the runner host as fully compromised whenever running untrusted code.

## License

MIT

# Fresh install (with Docker) + register + harden

sudo WITH_DOCKER=1 ./scripts/setup.sh

# Re-register everything if needed

sudo FORCE_REREG=1 ./scripts/register-from-json.sh

# Update runner binaries in place later

sudo ./scripts/update.sh

# Uninstall everything (keep user/config if you want)

sudo KEEP_USER=1 LEAVE_CONFIG=1 ./scripts/uninstall.sh
