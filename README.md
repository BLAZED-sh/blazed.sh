# blazed.sh CLI

A single-file bash CLI **and MCP server** for the [blazed.sh](https://blazed.sh) API — the Web3 PaaS that runs Docker containers and NodeJS scripts co-located with fully-synced Ethereum nodes.

```
$ blazed.sh container create web --image nginx:latest -p 8080 -e NODE_ENV=production
Created container web (id: 8f2k1c9d7e3a5b1)

$ blazed.sh container ports 8f2k1c9d7e3a5b1
CONTAINER  HOST
8080       30123

$ blazed.sh script create watcher --file mempool.js && blazed.sh script run <id>
$ blazed.sh script logs <id> --follow
```

## Install

Copy the `blazed.sh` file anywhere on your `PATH` and make it executable:

```sh
install -m 755 blazed.sh ~/.local/bin/blazed.sh
```

**Dependencies:** `bash` ≥ 4, `curl`, and `jq`. jq is mandatory — it is what guarantees your script code, env values, and log output survive JSON encoding/decoding byte-for-byte; the CLI never hand-interpolates JSON.

## Authentication

Get an API key from [panel.blazed.sh](https://panel.blazed.sh), then either:

```sh
export BLAZED_API_KEY=...     # environment variable, or
blazed.sh config set-key      # prompts silently, stores in the config file (chmod 600)
```

The config file is `${XDG_CONFIG_HOME:-~/.config}/blazed/config` with plain `key=value` lines (`api_key=...`, `api_url=...`). It is parsed, never sourced. Precedence:

| Setting | Order (high → low) |
|---|---|
| API key | `BLAZED_API_KEY` env → config file |
| Base URL | `--api-url` flag → `BLAZED_API_URL` env → config file → `https://backend.blazed.sh` |

`blazed.sh config show` prints the resolved configuration with the key masked.

## Commands

```
blazed.sh [--json] [--api-url URL] <resource> <command> [flags] [args]
```

### Containers

```sh
# Deploy a container (name is positional, --image required)
blazed.sh container create my-app --image nginx:latest \
    -e NODE_ENV=production -e PORT=3000 \      # repeatable; or --env-file FILE
    -p 8080 -p 443 \                           # container ports to expose (plain numbers)
    --cmd "node server.js" \                   # start command (split on spaces server-side)
    --tty \                                    # or --no-tty; omitted if not given
    --volume-id vol123 --mount-path /data      # optional volume attach

blazed.sh container list                       # table: ID NAME IMAGE STATUS
blazed.sh container get    <id>                # full record as JSON
blazed.sh container stop   <id>                # -> "Container <id>: stopping"
blazed.sh container delete <id>                # alias: rm
blazed.sh container logs   <id> [-f|--follow] [--interval SECS]   # default 2s
blazed.sh container ports  <id>                # assigned host ports
```

**Ports:** you only declare which *container* ports to expose (`-p 8080`, plain numbers 1–65535). The platform auto-assigns the public host ports — read them back with `blazed.sh container ports <id>`, which returns the container→host mapping.

### Scripts

NodeJS scripts run in a containerized environment with `ethers.js`/`web3.js` preinstalled and an Ethereum node reachable at `ws://blazed_infra_eth-execution:8545`.

```sh
blazed.sh script create my-script --file bot.js   # from a file
blazed.sh script create my-script --code 'console.log("hi")'
cat bot.js | blazed.sh script create my-script -  # from stdin (pipe or "-")

blazed.sh script update <id> --name new-name      # and/or --file/--code/- (partial update)
blazed.sh script list                             # table: ID NAME LAST_EXIT STATUS
blazed.sh script get    <id>                      # record incl. code + current runner
blazed.sh script run    <id>                      # -> "Script <id>: running"
blazed.sh script stop   <id>                      # -> "Script <id>: stopped"
blazed.sh script delete <id>                      # alias: rm
blazed.sh script logs   <id> [-f|--follow] [--interval SECS]
```

### Output modes and exit codes

Human-friendly output is the default; `--json` prints the raw API response (works on any command, useful for piping into `jq`). `logs` always writes plain log text to stdout, so it composes: `blazed.sh script logs <id> | grep ERROR`.

| Exit code | Meaning |
|---|---|
| 0 | success |
| 1 | API error (HTTP ≥ 400) or network failure |
| 2 | usage error, missing dependency, or missing API key |
| 130 | interrupted (Ctrl-C during `--follow`) |

Errors always go to stderr, with the API's response body included.

## MCP mode

`blazed.sh mcp` runs the same script as an [MCP](https://modelcontextprotocol.io) stdio server, exposing 15 tools that map 1:1 to the API:

`blazed_create_container`, `blazed_list_containers`, `blazed_get_container`, `blazed_stop_container`, `blazed_delete_container`, `blazed_container_logs`, `blazed_container_ports`, `blazed_create_script`, `blazed_update_script`, `blazed_list_scripts`, `blazed_get_script`, `blazed_run_script`, `blazed_stop_script`, `blazed_delete_script`, `blazed_script_logs`

Register it with Claude Code — globally:

```sh
claude mcp add --scope user blazed -- /path/to/blazed.sh mcp
```

or per-project via the `.mcp.json` in this repo. The API key is picked up from the config file or `BLAZED_API_KEY`; to pass it explicitly, add an `"env": {"BLAZED_API_KEY": "..."}` block to the server entry. Without a key the server exits at startup with a clear message on stderr (Claude Code shows this as "Failed to connect").

Notes:

- stdout is protocol-only in MCP mode; all diagnostics go to stderr.
- The server is synchronous (one request at a time) — fine for a single agent.
- A malformed request gets a JSON-RPC error response; it never kills the server.

## API reference

The CLI targets the blazed.sh backend API, also documented on the [docs page](https://blazed.sh/docs). Summary:

| Endpoint | Notes |
|---|---|
| `POST /api/containers` | `ports` is an array of plain port-number strings (`["8080"]`) — host ports are auto-assigned. Also accepts `volumeId`/`mountPath`. Returns 201. |
| `GET /api/containers` · `GET /api/containers/:id` · `DELETE /api/containers/:id` | List, get, delete. Delete returns 204. |
| `POST /api/containers/:id/stop` | Returns `{"status":"stopping"}`. |
| `GET /api/containers/:id/ports` | Returns a map `{"8080": 30123}` (containerPort → auto-assigned hostPort). |
| `PATCH /api/scripts/:id` | Script update; partial — only provided fields change. |
| `GET /api/scripts` · `GET /api/scripts/:id` · `DELETE /api/scripts/:id` | List, get, delete. Delete returns 204. |
| `POST /api/scripts/:id/run` / `stop` | Return `{"status":"running"}` / `{"status":"stopped"}`. |
| `env` field | Newline-separated `KEY=VALUE` string. `cmd` is one string, split on spaces server-side — quoting inside it is not honored. |

## Development

`test/mock_server.py` (python3 stdlib only) mocks the backend as described above: it requires `Authorization: Bearer test-key`, validates the ports array like the real handler, returns the real response shapes (201 creates, 204 deletes, `stopping`/`running`/`stopped` statuses, ports map), grows log text by one line per request (to exercise `--follow`), returns HTTP 500 for any id equal to `err500`, and echoes every request body it receives so you can inspect the CLI's JSON encoding.

```sh
python3 test/mock_server.py 8787 &
export BLAZED_API_URL=http://127.0.0.1:8787 BLAZED_API_KEY=test-key

./blazed.sh container create web --image nginx:latest -e 'MSG=has spaces' -p 8080 --tty
./blazed.sh script logs anything --follow --interval 1   # Ctrl-C to stop
./blazed.sh script run err500                            # error-path check, exit 1

# MCP handshake without any server-side setup:
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | ./blazed.sh mcp
```

Static checks: `bash -n blazed.sh` and `shellcheck blazed.sh` (clean as of 0.11.0).

Out of scope for now: shell completion (the noun–verb structure makes it easy to add later).
