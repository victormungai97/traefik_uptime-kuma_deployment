# Uptime Kuma + Traefik (Docker Compose)

A provider-independent [Docker Compose](https://docs.docker.com/compose/) deployment of [Uptime Kuma](https://uptimekuma.co/) — with [Traefik](https://traefik.io/traefik/) providing reverse proxying, HTTP-to-HTTPS redirection, and automatic TLS certificates through [Let's Encrypt](https://letsencrypt.org/) — on an [Ubuntu Server](https://ubuntu.com/server).

The guide uses Ubuntu Server 22.04/24.04 LTS, but the deployment can be adapted to other Linux distributions and most VPS providers, dedicated servers, or other Linux-based infrastructure.

## Table of Contents

- [Architecture](#architecture)
- [Requirements](#requirements)
- [1. Create a Server](#1-create-a-server)
- [2. Configure DNS](#2-configure-dns)
- [3. Connect to the Server](#3-connect-to-the-server)
- [4. Update and Prepare Ubuntu](#4-update-and-prepare-ubuntu)
- [5. Configure the Firewall](#5-configure-the-firewall)
- [6. Install Docker Engine and Docker Compose](#6-install-docker-engine-and-docker-compose)
- [7. Prepare the Deployment Directory](#7-prepare-the-deployment-directory)
- [8. Configure Environment Variables](#8-configure-environment-variables)
- [9. Configure Docker Compose](#9-configure-docker-compose)
- [10. Deploy the Services](#10-deploy-the-services)
- [11. Access Uptime Kuma](#11-access-uptime-kuma)
- [12. Verify the Deployment](#12-verify-the-deployment)
- [13. Useful Docker Compose Commands](#13-useful-docker-compose-commands)
- [14. Updating the Deployment](#14-updating-the-deployment)
- [15. Backups and Recovery](#15-backups-and-recovery)
- [Weekly automated maintenance](#weekly-automated-maintenance)
  - [Encrypted off-site backups using Restic](#encrypted-off-site-backups-using-Restic)
- [16. Security Recommendations](#16-security-recommendations)
- [17. Troubleshooting](#17-troubleshooting)
- [Repository Structure](#repository-structure)
- [License](#license)

---

## Architecture

The deployment consists of two Docker containers:

| Service     | Responsibility                                                                |
| ----------- | ----------------------------------------------------------------------------- |
| Traefik     | Reverse , HTTP-to-HTTPS redirection, and automatic TLS certificate management |
| Uptime Kuma | Website, server, application, and service monitoring                          |

Traffic follows this route:

```text
                 Internet
                    |
                    |
              Ports 80 / 443
                    |
                    v
              +-----------+
              |  Traefik  |
              |  Reverse  |
              |      |
              +-----------+
                    |
                    |
              Docker Network
                    |
                    v
             +-------------+
             | Uptime Kuma |
             |   Port 3001 |
             +-------------+
                    |
                    v
              Persistent Data
              ./uptime-kuma-data
```

Uptime Kuma is not exposed directly to the public internet. Traefik handles incoming HTTP and HTTPS requests and forwards them to the Uptime Kuma container through a private Docker network.

Let's Encrypt certificates are requested and renewed automatically by Traefik.

## Requirements

### Server requirements

The following specifications are suitable for an initial deployment with a modest number of monitoring checks:

| Resource         | Recommended starting specification                                        |
| ---------------- | ------------------------------------------------------------------------- |
| Operating System | Ubuntu Server 22.04 or 24.04 LTS                                          |
| CPU              | 1 vCPU                                                                    |
| RAM              | 1 GB                                                                      |
| Storage          | 30 GB SSD                                                                 |
| Public IP        | 1 public IPv4 address                                                     |
| Network          | Internet connectivity                                                     |
| Root Access      | Full or sudo access for package maintenance, service control and backups. |

Actual resource requirements depend on the number of monitors, check frequency, notification integrations, and monitoring history retained.

For a larger deployment, consider increasing RAM and storage.

### Other requirements

Before deployment, ensure you have:

- A server with SSH access and administrative privileges.
- A domain name or subdomain, for example `status.example.com`.
- Access to the domain's DNS management panel.
- An email address for Let's Encrypt certificate registration.
- A local computer with an SSH client.

## 1. Create a Server

Create a VPS or provision a server with your preferred infrastructure provider.

The deployment is not tied to any particular provider. You can use a cloud VPS, a dedicated server, or a suitable virtual machine.

During server creation, use the following configuration as a guide:

| Setting          | Value                   |
| ---------------- | ----------------------- |
| Operating System | Ubuntu Server 24.04 LTS |
| CPU              | 1 vCPU                  |
| RAM              | 1 GB                    |
| Storage          | 30 GB SSD               |
| Network          | Public IPv4 enabled     |
| Authentication   | SSH key preferred       |

If your provider offers a choice between password and SSH-key authentication, prefer SSH keys.

Record the following information after provisioning:

- Public IPv4 address.
- SSH username.
- SSH port (usually `22`).
- SSH private key location, if applicable.

**Important:** Ensure that the provider's firewall or network security rules allow inbound TCP traffic on ports `22`, `80`, and `443`.

You can restrict SSH access to your own IP address where practical.

## 2. Configure DNS

Create a DNS record for the hostname that will be used to access Uptime Kuma.

For example, if you intend to use:

```text
status.example.com
```

Create the following DNS record:

| Type | Name   | Value                 |
| ---- | ------ | --------------------- |
| A    | status | YOUR_SERVER_PUBLIC_IP |

Replace `YOUR_SERVER_PUBLIC_IP` with the actual public IP address of your server.

If you also have IPv6 configured and reachable, you may create an AAAA record.

**Important:** Do not create an AAAA record pointing to an IPv6 address that is not correctly configured or reachable. An incorrect AAAA record can cause certificate issuance or website access problems.

Allow time for DNS propagation.

You can verify the DNS record from your local computer:

```bash
dig +short status.example.com
```

The command should return your server's public IP address.

If `dig` is unavailable, you can install it on Ubuntu with:

```bash
sudo apt install dnsutils
```

Alternatively, use an online DNS lookup service.

## 3. Connect to the Server

From your local computer, connect using SSH.

For SSH key authentication:

```bash
ssh -i /path/to/private-key username@YOUR_SERVER_PUBLIC_IP
```

For password authentication:

```bash
ssh username@YOUR_SERVER_PUBLIC_IP
```

Replace the placeholders with your actual SSH details.

Once connected, confirm the operating system:

```bash
lsb_release -a
```

You should see an Ubuntu release.

Additionally, check the Ubuntu version:

```bash
lsb_release -cs   # Shows the codename (e.g., 'jammy' for 22.04)
```

## 4. Update and Prepare Ubuntu

Update the package index and install available updates:

```bash
sudo apt update
sudo apt upgrade -y
```

Install some useful utilities:

```bash
sudo apt install -y \
    ca-certificates \
    curl \
    gnupg \
    git \
    nano \
    ufw \
    dnsutils
```

Optionally, set the server's timezone:

```bash
sudo timedatectl set-timezone Africa/Nairobi
```

Verify the configured timezone:

```bash
timedatectl
```

Using the appropriate timezone makes it easier to interpret system logs and scheduled maintenance times.

## 5. Configure the Firewall

Ubuntu commonly uses UFW (Uncomplicated Firewall) as its host firewall.

Before enabling UFW, allow SSH traffic. Otherwise, you may lock yourself out of the server.

Allow SSH:

```bash
sudo ufw allow OpenSSH
```

Allow HTTP and HTTPS:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

Enable the firewall:

```bash
sudo ufw enable
```

Check its status:

```bash
sudo ufw status verbose
```

The expected allowed ports are:

| Port | Protocol | Purpose                               |
| ---- | -------- | ------------------------------------- |
| 22   | TCP      | SSH administration                    |
| 80   | TCP      | HTTP and Let's Encrypt HTTP challenge |
| 443  | TCP      | HTTPS                                 |

Do not expose Uptime Kuma's internal port `3001` publicly. Traefik will communicate with it through Docker networking.

If your infrastructure provider has a separate firewall or security group, configure the same inbound rules there.

_PS:_ For a more in-depth guide on:

- setting up, configuring and securing the server, feel free to follow this [tutorial](https://www.digitalocean.com/community/tutorials/initial-server-setup-with-ubuntu) from [DigitalOcean](https://www.digitalocean.com).
- setting up firewall, visit DigitalOcean's tutorials on [UFW Essentials](https://www.digitalocean.com/community/tutorials/ufw-essentials-common-firewall-rules-and-commands) and [Ubuntu Firewall setup using UFW](https://www.digitalocean.com/community/tutorials/how-to-set-up-a-firewall-with-ufw-on-ubuntu).

## 6. Install Docker Engine and Docker Compose

This deployment uses Docker Engine and the Docker Compose plugin.

The following instructions use Docker's official Ubuntu package repository.

### 6.1 Remove conflicting packages

If you have previously installed older or conflicting Docker packages, remove them:

```bash
sudo apt remove -y $(dpkg --get-selections docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc | cut -f1)
```

`apt` might report that you have none of these packages installed.

This does not remove data stored in `/var/lib/docker`, but take care if the server already hosts Docker workloads. For a clean installation, with clean up of any existing data, follow the [Docker Engine uninstall](https://docs.docker.com/engine/install/ubuntu/#uninstall-docker-engine) guide.

### 6.2 Add Docker's official GPG key

Create the keyrings directory:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
```

Download Docker's GPG key:

```bash
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
```

Set its permissions:

```bash
sudo chmod a+r /etc/apt/keyrings/docker.asc
```

### 6.3 Add the Docker repository

Add the repository to APT sources:

```bash
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
```

Update the package index:

```bash
sudo apt update
```

### 6.4 Install Docker Engine and Compose

Install the required packages:

```bash
sudo apt install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
```

Start Docker and enable it to run automatically at boot:

```bash
sudo systemctl enable --now docker
```

Verify Docker:

```bash
sudo systemctl status docker
sudo docker --version
```

Verify Docker Compose:

```bash
sudo docker compose version
```

Run a test container:

```bash
sudo docker run hello-world
```

This command downloads a test image and runs it in a container. When the container runs, it prints a confirmation message and exits.
If the test completes successfully, Docker is installed and operational.

### 6.5 Optional: Run Docker without sudo

You may add your user to the Docker group:

```bash
# Create the docker group, if does not exist
sudo groupadd docker
# Add your user to the docker group.
sudo usermod -aG docker $USER
```

Log out and reconnect for the group membership to take effect.

Alternatively, to apply the new group membership immediately, type the following:

```bash
newgrp docker
```

Confirm that your user is now added to the docker group by typing:

```bash
groups
```

The output will include your user, for example, as follows:

```bash
`username` sudo docker
```

Verify that you can run `docker` commands without `sudo`:

```bash
docker run hello-world
```

If you initially ran Docker CLI commands using `sudo` before adding your user to the `docker` group, you may see the following error:

```text
WARNING: Error loading config file: /home/user/.docker/config.json -
stat /home/user/.docker/config.json: permission denied
```

This error indicates that the permission settings for the `~/.docker/` directory are incorrect, due to having used the `sudo` command earlier.

To fix this problem, either remove the `~/.docker/` directory (it's recreated automatically, but any custom settings are lost) via:

```bash
rm -rf ~/.docker
```

or change its ownership and permissions using the following commands:

```bash
sudo chown "$USER":"$USER" /home/"$USER"/.docker -R
sudo chmod g+rwx "$HOME/.docker" -R
```

**Security warning:** Membership in the Docker group effectively grants root-level privileges on the server. Only add trusted administrative users.

With a small dedicated monitoring server, continuing to use `sudo docker` is also perfectly reasonable.

## 7. Prepare the Deployment Directory

Create a directory for the deployment. This guide uses `/opt/uptime-kuma`:

```bash
sudo mkdir -p /opt/uptime-kuma
```

Assign ownership to your administrative user:

```bash
sudo chown "$USER":"$USER" /opt/uptime-kuma
```

Move into the directory:

```bash
cd /opt/uptime-kuma
```

If you are deploying from this Git repository, clone it here or copy its contents into this directory.

For example:

```bash
git clone YOUR_REPOSITORY_URL .
```

Replace `YOUR_REPOSITORY_URL` with the actual repository URL.

If you are setting up the files manually, create the necessary files and directories as described below.

## 8. Configure Environment Variables

Create a your local environment file (`.env`) from the example:

```bash
cp .env.example .env
nano .env
```

Set the following configuration values for your deployment:

```dotenv
# Public hostname used to access Uptime Kuma
DOMAIN=status.example.com

# Email address used for Let's Encrypt registration
ACME_EMAIL=admin@example.com
```

Replace the example values with your actual domain and email address.

Save the file.

Restrict access to the environment file:

```bash
chmod 600 .env
```

The `.env` file contains deployment configuration and is excluded from Git in this repository. Do not commit it, especially if it contains private information or secrets.

## 9. Configure Docker Compose

This repository comes with a pre-configured Compose file (`compose.yaml`). This file uses bind-mounted directories in the repository folder. Create them if they do not already exist:

```bash
# Create the certificate storage and monitoring data directories
mkdir -p letsencrypt uptime-kuma-data
# Create the ACME storage file
touch letsencrypt/acme.json
# Restrict the ACME storage file's permissions
chmod 600 letsencrypt/acme.json
```

These directories hold important persistent data:

| Path                    | Contents                                                       |
| ----------------------- | -------------------------------------------------------------- |
| `uptime-kuma-data/`     | Uptime Kuma database, settings, monitors, and application data |
| `letsencrypt/acme.json` | Traefik ACME account and certificate information               |

As such, these folders, and their contents in particular, need to be kept private. Do not commit their contents to Git. Back them — especially the ACME file — up securely.

### Configuration notes

**Traefik**

Traefik is responsible for:

- Listening for incoming HTTP and HTTPS connections.
- Redirecting HTTP requests to HTTPS.
- Discovering Docker containers through Docker labels.
- Routing requests to the appropriate service.
- Obtaining and renewing Let's Encrypt certificates.

The Traefik dashboard is disabled in this configuration.

**Uptime Kuma**

Uptime Kuma:

- Runs on its internal port `3001`.
- Stores its persistent application data in `./uptime-kuma-data`.
- Is accessible externally through Traefik.
- Is not published directly on the host's network interfaces.

**Docker network**

Both services share an external Docker network named `web`.

This allows Traefik to communicate with Uptime Kuma without exposing Uptime Kuma's internal port to the host.

Before deploying the services, ensure to create the network:

```bash
sudo docker network create web
```

**Let's Encrypt**

Traefik uses the HTTP-01 challenge to obtain certificates.

For this to work:

- The domain must resolve to the server.
- TCP port `80` must be reachable from the internet.
- TCP port `443` must be reachable for HTTPS access.
- No other service should be occupying these ports.

**Deployment**

It is advised to always deploy and host this monitoring setup in it's own server **independent of the infrastructure it monitors**. Should it be deployed together with the application on the same server and the application goes down taking the monitoring with it, you'll have built an alarm system that fails exactly when you need it most.

Considering that a dedicated monitoring VPS can:

1. Cost well under $5/month, following the recommended starting specifications;
2. Be used in monitoring multiple applications and services, and;
3. Send alerts through external channels (email, Telegram, webhook) for each distinct monitored application / service,

It makes sense — and easily translates into being a high-value infrastructure investment — to deploy the monitoring independently.

You can read more on deployment [here](https://massivegrid.com/blog/uptime-kuma-ubuntu-vps/), with Traefik used in place of Nginx in this repository.

### Important version note

This deployment uses the official Uptime Kuma `2` image tag, which follows the latest release in the v2 major-version series. This is intentional and follows the project's recommended image-tagging [approach](https://hub.docker.com/r/louislam/uptime-kuma#tags). Administrators should nevertheless review release notes and perform backups before updating production deployments.

As for Traefik, `v3.7` image tag is used. For a production deployment, this tag can be retained or be adjusted to a specific tested release or digest. This gives you more predictable upgrades and reduces the risk of an unexpected image update changing the deployment.

Check the official project release information before choosing the exact versions:

- [Uptime Kuma releases](https://github.com/louislam/uptime-kuma/releases)
- [Traefik releases](https://github.com/traefik/traefik/releases)

## 10. Deploy the Services

Before starting the deployment, check that the Compose configuration is valid:

```bash
docker compose config
```

If the configuration is valid, download the images:

```bash
docker compose pull
```

Start the containers in the background:

```bash
docker compose up -d
```

Check the status of the running containers:

```bash
docker compose ps
```

Both `traefik` and `uptime-kuma` should show as running.

## 11. Access Uptime Kuma

Open your browser and navigate to:

```text
https://status.example.com
```

Replace the example hostname with the domain configured in your `.env` file.

On the first visit, Uptime Kuma should present its initial setup screen.

Create the administrator account and a strong password.

### Persistence

For storage, as Uptime Kuma 2 comes with an option to use a MariaDB database for persisting the monitor data, instead of the previously used SQLite, we recommend using the embedded MariaDB database which offers greatly increased performance, as well as ease of deployment.

However, this is optional and you can, as well, use the traditional SQLite or connect Uptime Kuma to an external MariaDB database (though one could argue that this beats the purpose of having an independent monitoring tool 😏).

### Monitoring

Once setup is complete, you can begin adding monitors.

Examples of things you can monitor include:

- Websites and web applications.
- HTTP and HTTPS endpoints.
- TCP ports.
- DNS records.
- Ping targets.
- Docker containers, where appropriately configured.
- Other services supported by Uptime Kuma.

Refer to the [Uptime Kuma documentation](https://github.com/louislam/uptime-kuma/wiki) for details on supported monitor types and notification integrations.

## 12. Verify the Deployment

After accessing the application, verify the following.

### 12.1 Check container status

```bash
docker compose ps
```

Confirm that both services are running.

### 12.2 Inspect Traefik logs

```bash
docker compose logs -f traefik
```

Look for successful startup and certificate acquisition.

Certificate issuance may take a short time after the first deployment.

### 12.3 Inspect Uptime Kuma logs

```bash
docker compose logs -f uptime-kuma
```

Look for application startup messages and any errors.

### 12.4 Open the application

Visit:

```text
https://status.example.com
```

Confirm that:

- The application loads.
- The browser reports a valid HTTPS connection.
- The certificate is issued for the correct hostname.
- HTTP requests redirect to HTTPS.

You can also inspect the HTTP response:

```bash
curl -I https://status.example.com
curl -I http://status.example.com
```

Confirm that HTTPS works and HTTP redirects to HTTPS. Certificate issuance can take a short time after first startup.

### 12.5 Verify persistence

After creating your administrator account, restart the containers:

```bash
docker compose restart
```

Visit the application again and confirm that your account and configuration remain available.

The persistent volume should preserve Uptime Kuma's data across container restarts and image replacements.

## 13. Useful Docker Compose Commands

Run these commands from `/opt/uptime-kuma`.

| Operation                  | Command                              |
| -------------------------- | ------------------------------------ |
| Start services             | `docker compose up -d`               |
| Stop services              | `docker compose stop`                |
| Stop and remove containers | `docker compose down`                |
| Restart services           | `docker compose restart`             |
| View running services      | `docker compose ps`                  |
| View all logs              | `docker compose logs -f`             |
| View Traefik logs          | `docker compose logs -f traefik`     |
| View Kuma logs             | `docker compose logs -f uptime-kuma` |
| Pull updated images        | `docker compose pull`                |
| Recreate containers        | `docker compose up -d`               |
| Validate Compose file      | `docker compose config`              |

**Important:** `docker compose down` removes containers and the Compose-created network, but does not remove the bind-mounted data directories used by this deployment.

Avoid using `docker compose down -v` or manually deleting the data directories unless you intentionally want to remove persistent application data.

## 14. Updating the Deployment

Periodically update Docker images to receive bug fixes, security patches, and new features.

Before updating, create a backup of the application data.

Pull the latest images permitted by your configured tags:

```bash
docker compose pull
```

Recreate the containers:

```bash
docker compose up -d
```

Check their status:

```bash
docker compose ps
```

Review the logs:

```bash
docker compose logs --tail=100
```

For production environments, avoid blindly updating to an untested image.

A safer process is:

1. Review the release notes for Uptime Kuma and Traefik.
2. Back up the existing data.
3. Pin the desired image versions in `compose.yaml`.
4. Pull the selected versions.
5. Recreate the containers.
6. Verify that monitoring and notifications still work.

_PS_: If this is your first time using Docker / Docker Compose (or if you wish to refresh your knowledge), visit DigitalOcean's [Docker](https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-on-ubuntu-22-04#step-3-using-the-docker-command) and [Docker Compose](https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-compose-on-ubuntu-22-04#step-2-setting-up-a-docker-compose-yml-file) tutorials for additional information and guidance on usage of Docker and Docker Compose.

## 15. Backups and Recovery

Uptime Kuma stores its application data in:

```text
/opt/uptime-kuma/uptime-kuma-data
```

Traefik stores Let's Encrypt certificate information in:

```text
/opt/uptime-kuma/letsencrypt
```

The deployment configuration is stored in:

```text
/opt/uptime-kuma/compose.yaml
/opt/uptime-kuma/.env
```

Back up all these items.

### 15.1 Basic backup procedure

For a simple, consistent filesystem backup, briefly stop the services before copying their data:

```bash
cd /opt/uptime-kuma

docker compose stop

sudo tar -czf "/root/uptime-kuma-backup-$(date +%F-%H%M%S).tar.gz" \
    -C /opt/uptime-kuma \
    compose.yaml \
    .env \
    uptime-kuma-data \
    letsencrypt

docker compose start
```

This momentarily interrupts monitoring while the backup is created.

Store backups somewhere separate from the server, preferably encrypted remote storage.

Do not rely exclusively on backups stored on the same VPS / server.

### 15.2 Recovery procedure

The recovery process restores the deployment configuration, Uptime Kuma application data, and Traefik certificate information from a previously created backup.

There are two supported recovery methods:

1. Restoring a local .tar.gz backup.
2. Restoring an encrypted Restic snapshot from off-site storage.

Both methods ultimately produce the same application archive, which must be extracted into the actual deployment directory.

> **Important**: The backup archive contains `compose.yaml`, `.env`, `uptime-kuma-data/`, and `letsencrypt/`. It does not contain the Git repository, maintenance scripts, systemd units, or Restic configuration file. Obtain the deployment files separately from the Git repository or another trusted copy.

#### 15.2.1 Prepare the replacement server

To restore:

1. Provision a replacement Ubuntu server.
2. Install Docker Engine and the Docker Compose plugin using the installation procedure described earlier in this guide.
3. Obtain the deployment repository and place its contents in `/opt/uptime-kuma`.

For example:

```bash
sudo mkdir -p /opt/uptime-kuma
sudo chown "$USER":"$USER" /opt/uptime-kuma

git clone YOUR_REPOSITORY_URL /opt/uptime-kuma
```

Replace `YOUR_REPOSITORY_URL` with the actual repository URL.

If the original Git repository is unavailable, obtain a trusted copy of the deployment files from another source.

Create the external Docker network required by the Compose configuration:

```bash
sudo docker network create web
```

If the network already exists, Docker will report that it exists; there is no need to recreate it.

#### 15.2.2 Method A: Restore a local backup archive

If you have a local or separately downloaded backup archive, identify its full path.

For example:

```dotenv
ARCHIVE="/path/to/uptime-kuma-20261108T033000Z.tar.gz"
```

First, verify that the archive can be read:

```bash
sudo tar -tzf "$ARCHIVE" >/dev/null
```

Extract it into a temporary directory first:

```bash
sudo mkdir -p /tmp/uptime-kuma-restore

sudo tar -xzf "$ARCHIVE" \
 -C /tmp/uptime-kuma-restore
```

Inspect the extracted contents:

```bash
sudo ls -la /tmp/uptime-kuma-restore
```

You should find:

```text
compose.yaml
.env
uptime-kuma-data/
letsencrypt/
```

If these files and directories are present, proceed with the restoration.

For a fresh deployment directory, extract the archive into the actual deployment directory:

```bash
sudo tar -xzf "$ARCHIVE" \
 -C /opt/uptime-kuma
```

This restores the Compose configuration, environment file, application data, and certificate information.

If restoring over an existing deployment, stop the existing services first and preserve the old application data directories separately. Do not merge old application data with restored data.

#### 15.2.3 Method B: Restore an encrypted Restic snapshot

If your backup exists in the configured Restic repository, first ensure Restic is installed.

Install or recreate the Restic environment configuration file using the instructions in Section 16. Do not assume that this file is included in the application backup.

You must have the correct:

- Restic repository URL.

- Restic encryption password.

- S3-compatible storage access key.

- S3-compatible storage secret key.

The Restic password is particularly important: without it, the repository contents cannot be decrypted.

List available snapshots:

```bash
sudo bash -c \
 'set -a; source /etc/uptime-kuma-restic.env; set +a; restic snapshots --tag uptime-kuma'
```

Identify the snapshot you wish to restore and copy its snapshot ID.

Restore the selected snapshot into a temporary directory:

```bash
sudo mkdir -p /tmp/uptime-kuma-restic-restore

sudo bash -c \
 'set -a; source /etc/uptime-kuma-restic.env; set +a; restic restore REPLACE_WITH_SNAPSHOT_ID --target /tmp/uptime-kuma-restic-restore'
```

Replace `REPLACE_WITH_SNAPSHOT_ID` with the actual snapshot ID.

Restic reconstructs the original filesystem paths beneath the specified target directory. Consequently, the archive will normally be located somewhere under:

```bash
/tmp/uptime-kuma-restic-restore/var/backups/uptime-kuma/
```

Locate the restored archive:

```bash
sudo find /tmp/uptime-kuma-restic-restore \
 -type f \
 -name 'uptime-kuma-\*.tar.gz'
```

Identify the archive corresponding to the snapshot you selected.

For example:

```dotenv
ARCHIVE="/tmp/uptime-kuma-restic-restore/var/backups/uptime-kuma/uptime-kuma-20261108T033000Z.tar.gz"
```

The actual filename and path depend on the snapshot.

Verify the archive:

```bash
sudo tar -tzf "$ARCHIVE" >/dev/null
```

Then extract it into the actual deployment directory:

```bash
sudo tar -xzf "$ARCHIVE" \
 -C /opt/uptime-kuma
```

At this point, both recovery methods have produced the same deployment directory structure.

#### 15.2.4 Verify the restored configuration and permissions

Before starting the services, inspect the restored environment file:

```bash
sudo nano /opt/uptime-kuma/.env
```

Confirm that:

- `DOMAIN` points to the correct public hostname.

- `ACME_EMAIL` contains the correct email address.

Restrict access to the environment file:

```bash
sudo chmod 600 /opt/uptime-kuma/.env
```

Ensure that the Let's Encrypt storage file exists and has restrictive permissions:

```bash
sudo touch /opt/uptime-kuma/letsencrypt/acme.json
sudo chmod 600 /opt/uptime-kuma/letsencrypt/acme.json
```

Do not replace an existing restored `acme.json` with an empty file. The touch command above only creates it if it is missing.

Ensure the persistent application data directory exists:

```bash
sudo mkdir -p /opt/uptime-kuma/uptime-kuma-data
```

Check that the external Docker network exists:

```bash
sudo docker network inspect web
```

If it does not exist, create it:

```bash
sudo docker network create web
```

Validate the Compose configuration:

```bash
cd /opt/uptime-kuma

sudo docker compose config --quiet
```

#### 15.2.5 Start and verify the restored deployment

Pull the required container images:

```bash
cd /opt/uptime-kuma

sudo docker compose pull
```

Start the services:

```bash
sudo docker compose up -d
```

Check their status:

```bash
sudo docker compose ps
```

Inspect the logs if necessary:

```bash
sudo docker compose logs --tail=100
```

Verify that:

1. The Docker socket proxy is running.

2. Traefik is running and healthy.

3. Uptime Kuma is running and healthy.

4. Uptime Kuma's previous monitors and application settings are present.

5. The public hostname resolves to the replacement server.

6. HTTPS works and the certificate is valid.

7. Monitoring checks are executing successfully.

If Traefik cannot obtain or renew a certificate, inspect its logs and verify DNS and firewall configuration.

#### 15.2.6 Restore the maintenance automation

The application backup does not contain the maintenance script or systemd units.

Obtain these files from the deployment repository and ensure that they are installed in the correct locations.

For example:

```bash
sudo install -D -m 0750 \
 /opt/uptime-kuma/scripts/weekly-maintenance.sh \
 /opt/uptime-kuma/scripts/weekly-maintenance.sh
```

If the repository files are already in the correct deployment directory, ensure the script is executable:

```bash
sudo chmod 0750 \
 /opt/uptime-kuma/scripts/weekly-maintenance.sh
```

Recreate the Restic environment configuration file separately, using the correct repository credentials and encryption password.

Then install and enable the systemd service and timer using the instructions in Section 16.

Finally, verify that the timer is active:

```bash
sudo systemctl enable --now uptime-kuma-maintenance.timer

sudo systemctl status uptime-kuma-maintenance.timer

sudo systemctl list-timers --all | grep uptime-kuma
```

#### 15.2.7 Recovery testing

For important deployments, periodically test recovery on a separate VPS or isolated environment.

A successful restoration should demonstrate that:

- The archive can be retrieved.

- The archive can be extracted.

- Docker Compose can reconstruct the services.

- Uptime Kuma retains its monitors, settings and historical data.

- Traefik can serve the application over HTTPS.

- The maintenance automation can be restored and executed.

Do not consider a backup verified simply because Restic reports that it uploaded successfully.

> A backup that has never been restored is not a verified recovery plan.

## Weekly automated maintenance

This repository includes an optional maintenance script and systemd timer:

- `scripts/weekly-maintenance.sh`
- `systemd/uptime-kuma-maintenance.service`
- `systemd/uptime-kuma-maintenance.timer`

### What the maintenance script does

1. Acquires a lock so two maintenance runs cannot overlap.
2. Checks the Compose project, Docker/Compose availability and backup directory.
3. In Restic mode, loads the root-only Restic environment file, ensures Restic
   is installed, and verifies repository access (or attempts initialization
   only when `--init-restic` is explicitly supplied).
4. Stops the Compose project briefly and creates a compressed archive of the
   project directory for a consistent copy of bind-mounted data.
5. Verifies the archive can be read, then restarts and checks the Compose services.
6. In default mode, uploads the archive to Restic and applies snapshot retention.
7. Runs Ubuntu package updates and removes unused packages,
   then checks that the Compose project is running.
8. Deletes local backup archives older than `RETENTION_DAYS` (default 30).

If the Restic upload or package maintenance fails, the local archive is retained for investigation/retry.
Should Ubuntu indicate that a reboot is required, a reboot-required marker is logged; the script does **not** reboot automatically.

The script logs to `/var/log/uptime-kuma-maintenance.log`.

### Backup location and contents

Backups are written to `/var/backups/uptime-kuma/` by default. Each archive contains `compose.yaml`, `.env`, `uptime-kuma-data/`, and `letsencrypt/`.

Archives contain credentials and application data. The script creates the backup directory with restrictive permissions and sets each archive to mode `600`.

Monitoring is interrupted briefly while containers are stopped to create the local archive. The potentially slower S3 upload happens after the services have restarted. Schedule the timer during a quiet maintenance window.

### Encrypted off site backups using Restic

[Restic](https://restic.net/) is the default off-site backup method facilitating uploading of backup archives to a [number](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html) of storage solutions, including S3-compatible storage service, which is the preferred solution in this script. However, within this script, Restic usage is **optional**.

In the default mode, the script validates the Restic configuration and repository, uploads the archive encrypted to S3 compatible storage, and applies the configured off-site snapshot retention. Use `--skip-restic` for local-only backups; this skips all Restic configuration, installation, repository, upload, and remote-retention operations. Local archive creation, integrity checking, local retention, and Ubuntu maintenance still run.

> A backup on the same VPS is not protection against VPS loss. If you skip Restic, arrange another off-host copy process.

#### Configure Restic

Restic encrypts backup contents on the server before sending them to the preferred service. Thus, on the service, create a private bucket with an associated application key restricted to that bucket. The key needs the permissions Restic requires to list, read, write
and delete repository objects so retention pruning can work.

On the server, create the configuration file for Restic:

```bash
sudo cp config/restic.env.example /etc/uptime-kuma-restic.env
sudo chown root:root /etc/uptime-kuma-restic.env
sudo chmod 600 /etc/uptime-kuma-restic.env
sudo nano /etc/uptime-kuma-restic.env
```

Example contents:

```bash
RESTIC_PASSWORD="<replace-with-a-long-unique-random-password>"
# Restic Repository Configuration (S3 prefix)
RESTIC_REPOSITORY="s3:http(s)://<s3-storage-service-domain>[:<s3-storage-service-port>]/<your-private-bucket>:uptime-kuma"
# S3-compatible storage service's API credentials
AWS_ACCESS_KEY_ID="<your_s3_access_key_id>"
AWS_SECRET_ACCESS_KEY="<your_s3_secret_access_key>"
# S3-compatible storage service's bucket's region, defaults to "us-east-1" if not specified
AWS_DEFAULT_REGION="<your_s3_bucket_region>"
```

Generate a strong password, for example:

```bash
openssl rand -base64 48
```

Keep the Restic password separately in a secure password manager or other
recovery location. Restic encrypts repository data client-side; **if you lose
the password, you cannot decrypt the backups**. Never commit this file or put
its contents in a public repository.

The example file is at `config/restic.env.example`. Copy it only as a template;
do not store real credentials in the project directory.

#### Install and initialize Restic

If Restic is missing during an interactive run, the script asks whether it may install Restic through APT. Use `--install-restic` to authorize automatic installation without a prompt. Non-interactive runs (including systemd) do not prompt: install Restic beforehand or pass `--install-restic`. The Restic repository must already be initialized; the script checks this before stopping services and creating the backup, but deliberately never initializes a repository automatically.

However, to prevent issues that may arise during running of the script, e.g. slow internet connection, which may extend the monitoring outage, it is advisable to install Restic once:

```bash
sudo apt-get update
sudo apt-get install -y restic
```

Additionally, The maintenance script checks that a configured Restic repository is accessible before it stops the containers. It does not silently initialize repositories. However, it contains an `--init-restic` flag which, when explicitly supplied, instructs the script to attempt initialization of the configured repository if its initial accessibility check fails and then verifies the repository. If the repository already exists and is accessible, explicitly passing `--init-restic` still results in the verification succeeds and the existing repository is used.

However, this check can also fail because of incorrect credentials, a wrong repository path or network problems and can cause unforeseen issues such as:

- accidentally creating the wrong repository, e.g. if there is a configuration mistake, perhaps using the wrong bucket or repository path.
- Existing repositories being treated as disposable.

Thus, similar to installation, it is best to initialize the repository deliberately immediately following installation:

```bash
sudo bash -c 'set -a; . /etc/uptime-kuma-restic.env; set +a; restic init'
```

Initialization is a one-time operation for a new repository. Installing Restic does not initialize a repository.

**Caution:** If passing `--init-restic` so as to initialize the configured destination if Restic considers it uninitialized, then verify the configuration before use.

### Maintenance script options

Run from the project directory or use the absolute path:

```bash
sudo /opt/uptime-kuma/scripts/weekly-maintenance.sh --help
```

| Invocation                       | Behaviour                                                                                                    |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| No flags                         | Local backup, then Restic upload (default)                                                                   |
| `--skip-restic`                  | Local backup only; skip all Restic checks, installation, initialization, upload and pruning                  |
| `--install-restic`               | If Restic is missing, install it through APT without prompting                                               |
| `--init-restic`                  | Attempt to initialize the configured repository, then verify it; existing accessible repositories are reused |
| `--install-restic --init-restic` | Install Restic if missing, attempt initialization, verify, then continue with upload                         |
| `--help`                         | Show usage                                                                                                   |

If Restic is missing and Restic mode is selected:

- With `--install-restic`, the script installs it automatically.
- Without that flag, an interactive run asks permission to install it.
- A non-interactive run (such as systemd) fails with an explanation rather
  than hanging or silently changing the server.

`--skip-restic` takes precedence over the other Restic flags. For example,
`--skip-restic --install-restic` still skips Restic entirely.

Examples:

```bash
# Default: local archive + encrypted Restic upload
sudo /opt/uptime-kuma/scripts/weekly-maintenance.sh

# Local archive only; manage/copy it yourself
sudo /opt/uptime-kuma/scripts/weekly-maintenance.sh --skip-restic

# Install Restic automatically if it is absent
sudo /opt/uptime-kuma/scripts/weekly-maintenance.sh --install-restic

# Initialize if needed, then verify and upload
sudo /opt/uptime-kuma/scripts/weekly-maintenance.sh --init-restic

# Install if needed, initialize if needed, then upload
sudo /opt/uptime-kuma/scripts/weekly-maintenance.sh --install-restic --init-restic
```

### Install the weekly systemd timer

The supplied service runs the script as root and the timer is configured for Sunday at 03:30 AM server-local time, with up to 15 minutes of randomized delay.

The service assumes the repository is installed at `/opt/uptime-kuma`. If you use a different path, edit `DEPLOY_DIR` in the script and `ExecStart` in the service unit.

From the repository directory:

#### a. Review the service file:

```ini
ExecStart=/opt/uptime-kuma/scripts/weekly-maintenance.sh
```

To use local-only backups, change it to:

```ini
ExecStart=/opt/uptime-kuma/scripts/weekly-maintenance.sh --skip-restic
```

If you want systemd to install Restic automatically when missing, add `--install-restic`. For a normal scheduled production setup, it is better to install Restic and initialize/verify the repository during provisioning, rather than have a weekly job initialize it.

#### b. Install and test the timer:

```bash
sudo install -D -m 0750 scripts/weekly-maintenance.sh /opt/uptime-kuma/scripts/weekly-maintenance.sh
sudo install -m 0644 systemd/uptime-kuma-maintenance.service /etc/systemd/system/uptime-kuma-maintenance.service
sudo install -m 0644 systemd/uptime-kuma-maintenance.timer /etc/systemd/system/uptime-kuma-maintenance.timer
sudo systemctl daemon-reload

# Run once manually first; inspect its output and logs.
sudo /opt/uptime-kuma/scripts/weekly-maintenance.sh

sudo systemctl enable --now uptime-kuma-maintenance.timer
```

For local-only mode, update `ExecStart` before enabling the timer and run
`sudo systemctl daemon-reload`.

Check the timer:

```bash
systemctl list-timers uptime-kuma-maintenance.timer
systemctl status uptime-kuma-maintenance.timer
```

### Run maintenance manually

```bash
sudo systemctl start uptime-kuma-maintenance.service
```

Inspect the result:

```bash
sudo systemctl status uptime-kuma-maintenance.service
sudo journalctl -u uptime-kuma-maintenance.service -n 100 --no-pager
sudo tail -n 100 /var/log/uptime-kuma-maintenance.log
```

You can also invoke the script directly:

```bash
sudo /opt/uptime-kuma/scripts/weekly-maintenance.sh
```

### Update policy and reboots

The script updates Ubuntu packages from configured APT repositories. It does **not** pull or upgrade Traefik or Uptime Kuma container images. Keep application image upgrades separate and review release notes, backups, and rollback options before upgrading.

The script does not reboot automatically. If the log reports that a reboot is required, schedule and perform it deliberately:

```bash
sudo reboot
```

After reconnecting, verify the deployment:

```bash
cd /opt/uptime-kuma
docker compose ps
docker compose logs --tail=100
```

## 16. Security Recommendations

This repository provides a basic deployment, not a complete server-hardening solution.

Consider the following additional precautions.

### Server security

- Use SSH key authentication instead of password authentication where possible.
- Disable direct root SSH login after confirming that another administrative account works.
- Keep Ubuntu packages updated.
- Restrict SSH access to trusted IP addresses where practical.
- Use strong administrator passwords.
- Monitor server resource usage and disk capacity.

### Docker security

- Do not expose Uptime Kuma's internal port `3001` directly to the internet.
- Avoid running unnecessary containers.
- Keep Docker Engine and container images updated.
- Restrict access to the Docker socket.

The Compose configuration mounts the Docker socket read-only:

```yaml
- "/var/run/docker.sock:/var/run/docker.sock:ro"
```

This prevents ordinary filesystem writes through that mount, but it does not make the Docker API safe to expose to an untrusted container. Access to the Docker socket can effectively provide extensive control over the host.

For a more security-conscious deployment, a Docker socket proxy with a restricted API surface has been implemented instead of mounting the Docker socket directly.

### Application security

- Use a strong and unique Uptime Kuma administrator password (You can use [LastPass](https://www.lastpass.com/)'s [online password generator](https://www.lastpass.com/features/password-generator)).
- Enable two-factor authentication if supported by your installed version.
- Keep Uptime Kuma updated.
- Do not expose the Traefik dashboard publicly without appropriate authentication and access controls.
- Configure notification channels so that monitoring alerts reach an independent destination.

### Monitoring reliability

A monitoring server cannot reliably report its own complete outage if it is unreachable.

Thus, if this server is being used to monitor other customer-facing systems for important environments, consider the following:

- Use an external monitoring provider to monitor the Uptime Kuma server itself.
- Send alerts through an independent notification provider.
- Back up monitoring data outside the server.
- **Consider deploying Uptime Kuma separately from the applications it monitors.**

For important environments, use an external monitoring service or a second monitoring location to check this server.

## 17. Troubleshooting

### Problem: The domain does not load

Check that DNS record resolves to the correct public IP:

```bash
dig +short status.example.com
```

Confirm that ports `80` and `443` are allowed by both the server firewall and the infrastructure provider's firewall:

```bash
sudo ufw status
```

Check whether another process is already using those ports:

```bash
sudo ss -tulpn | grep -E ':80|:443'
```

Inspect Traefik logs:

```bash
docker compose logs -f traefik
```

### Problem: Let's Encrypt certificate is not issued

Check the following:

- The DNS record resolves correctly to this server's public IP.
- Inbound TCP port `80` is reachable from the internet.
- The domain is not pointing to an incorrect IPv6 address.
- No other application is occupying port `80`.
- The ACME storage file (`letsencrypt/acme.json`) exists and has restricted permissions (`600`) that enables it to be writable by the Traefik container.

Inspect the logs:

```bash
docker compose logs traefik
```

Let's Encrypt also imposes rate limits. During troubleshooting, consider using its staging environment before repeatedly requesting production certificates. See the [Traefik ACME documentation](https://doc.traefik.io/traefik/https/acme/).

### Problem: Bad Gateway or 502 response

Check whether Uptime Kuma is running:

```bash
docker compose ps
```

Check its logs:

```bash
docker compose logs --tail=200 uptime-kuma
```

Confirm that:

- Both containers are attached to the `web` Docker network.
- The Traefik service label specifies / points to port `3001`.
- Uptime Kuma has completed startup.

### Problem: Uptime Kuma data disappears after a restart

Check that the persistent volume is correctly configured:

```yaml
volumes:
  - "./uptime-kuma-data:/app/data"
```

Also confirm that you are deploying from the same directory and have not accidentally created a different data directory.

### Problem: Docker Compose cannot find the environment variables

Ensure that:

- `.env` is in the same directory as `compose.yaml`.
- You are executing Docker Compose from that directory.
- The variable names in `.env` match those used in `compose.yaml`.

You can inspect the resolved Compose configuration with:

```bash
docker compose config
```

Be careful when sharing its output, since resolved configuration may contain sensitive values in other deployments.

---

## Repository Structure

The recommended repository structure is:

```text
uptime-kuma-traefik/
│
├── compose.yaml
├── .env.example
├── .gitignore
├── README.md
├── config/
│   └── restic.env.example
├── scripts/
│   └── weekly-maintenance.sh
├── systemd/
│   ├── uptime-kuma-maintenance.service
│   └── uptime-kuma-maintenance.timer
├── letsencrypt/
│   └── .gitkeep
└── uptime-kuma-data/
    └── .gitkeep
```

The `letsencrypt` and `uptime-kuma-data` data directories are created on the server and hold persistent application data outside the containers. Their contents are intentionally excluded from Git.

---

## License

This repository's original deployment configuration and documentation may be distributed under the [MIT License](https://opensource.org/license/mit).

Uptime Kuma and Traefik are separate projects with their own licenses and copyright notices. Refer to their respective repositories for licensing information:

- [Uptime Kuma](https://github.com/louislam/uptime-kuma)
- [Traefik](https://github.com/traefik/traefik)

---

## References

- [Docker Engine installation on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [Docker Compose documentation](https://docs.docker.com/compose/)
- [Traefik documentation](https://doc.traefik.io/traefik/)
- [Traefik Docker provider](https://doc.traefik.io/traefik/providers/docker/)
- [Let's Encrypt Website](https://letsencrypt.org/)
- [Let's Encrypt Documentation](https://letsencrypt.org/docs/)
- [Traefik Let's Encrypt configuration](https://doc.traefik.io/traefik/https/acme/)
- [Uptime Kuma Website](https://uptimekuma.co/)
- [DigitalOcean Tutorials](https://www.digitalocean.com/community/tutorials)
- [Uptime Kuma GitHub repository](https://github.com/louislam/uptime-kuma)
- [Uptime Kuma Wiki](https://github.com/louislam/uptime-kuma/wiki)
