FROM dockurr/proxmox-backup:latest

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY setup-static-pbs.sh /usr/local/bin/setup-static-pbs.sh

RUN --mount=type=tmpfs,dst=/run apt-get update && \
    apt-get install -y --no-install-recommends whois && \
    apt-get purge -y --autoremove && \
    rm -rf /var/lib/apt/lists/* && \
    chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/setup-static-pbs.sh && \
    mkdir -p /etc/proxmox-backup /var/lib/proxmox-backup/datastore /var/log/proxmox-backup /run/proxmox-backup && \
    chown -R backup:backup /etc/proxmox-backup /var/lib/proxmox-backup /var/log/proxmox-backup /run/proxmox-backup || true && \
    BUILD=Y PASSWORD=demo POSTFIX=N /usr/local/bin/entrypoint.sh