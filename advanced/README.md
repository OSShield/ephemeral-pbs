# Advanced PBS configuration container

Same base as the basic container, but the datastore, namespaces, users and tokens are defined in a small YAML file that is applied every time the container starts. The setup is idempotent, so you can edit the config and restart the container.

## YAML format

```yaml
datastore: data
default_token_secret: "12345678-1234-1234-1234-1234567890ab"

namespaces:
  level1:
    level2:
      level3:
  level1-2:

users:
  userA:
    password: "userA-password"
    namespaces: [level1, level1-2]
    permissions: [DatastoreBackup]
    token:
      - useratoken
    token_secret: "12345678-1234-1234-1234-1234567890ab"
  userB:
    namespaces: []
    permissions: [DatastoreRead]
    token:
      - userbtoken
```

Since YAML is parsed by bash, only this YAML subset is supported (two-space indentation, inline `[a, b]` lists or `- item` lists for tokens). Unknown keys stop the container with an error.

| Key | Description |
| --- | --- |
| `datastore` | Datastore name, created at `/var/lib/proxmox-backup/datastore`. Defaults to `data`. |
| `default_token_secret` | Secret for all tokens unless a user overrides it. Defaults to `12345678-1234-1234-1234-1234567890ab`. |
| `namespaces` | Nested namespace tree, created through the PBS API. |
| `users.<name>.password` | Password for `<name>@pbs`. Defaults to `<name>-password` (PBS requires at least 8 characters). |
| `users.<name>.namespaces` | Namespaces (e.g. `level1/level2`) the permissions apply to. Empty means the whole datastore. |
| `users.<name>.permissions` | PBS roles, e.g. `DatastoreBackup` or `DatastoreReader` (`DatastoreRead` is accepted as an alias). All permissions are set at the root level for now. |
| `users.<name>.token` | Token names to create for the user. |
| `users.<name>.token_secret` | Overrides `default_token_secret` for this user's tokens. |

## Behavior

- Users are created in the `pbs` realm, e.g. `userA@pbs`.
- ACLs are set on `/datastore/<datastore>/<namespace>` (or `/datastore/<datastore>`), for both the user and its tokens.
- Token secrets are overwritten with the configured fixed secret (stored as a yescrypt hash in `/etc/proxmox-backup/token.shadow`).
- After setup, every token is checked to authenticate with its secret. If setup or verification fails, the container stops.
- The configured datastores, users and tokens are printed to the log on startup.

## Run

```bash
cd advanced
docker compose up --build
```

The web UI is available at https://localhost:8008 (`root@pam` / `demo`).

`/run` must be a tmpfs (set in `compose.yml`), otherwise PBS rejects all logins. With plain `docker run`, pass `--tmpfs /run`.
