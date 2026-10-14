FROM dockurr/proxmox-backup:latest

ENV PASSWORD=demo \
    CONFIG_FILE=/etc/pbs-config.yml

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY setup-pbs-config.sh /usr/local/bin/setup-pbs-config.sh
COPY config.yml /etc/pbs-config.yml

RUN apt-get update && \
    apt-get install -y --no-install-recommends whois && \
    rm -rf /var/lib/apt/lists/* && \
    chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/setup-pbs-config.sh && \
    mkdir -p /etc/proxmox-backup /var/lib/proxmox-backup/datastore /var/log/proxmox-backup /run/proxmox-backup && \
    chown -R backup:backup /etc/proxmox-backup /var/lib/proxmox-backup /var/log/proxmox-backup /run/proxmox-backup
