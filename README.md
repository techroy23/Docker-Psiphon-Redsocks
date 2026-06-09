# Docker-Psiphon-Redsocks

A Docker base image that routes all outbound traffic through [Psiphon](https://psiphon.ca) via a transparent proxy stack (Redsocks + iptables). Import it into your Dockerfile to run any application behind Psiphon's censorship circumvention network.

## Features
- Ubuntu 24.04 base
- Downloads Psiphon tunnel core binary from official releases
- Redsocks for transparent TCP proxying
- iptables rules redirect all outbound traffic through Psiphon
- Psiphon SOCKS5 exposed on `0.0.0.0:40001` for external hosts
- Automatic monitoring and restart on failure (3 consecutive failures)
- Readiness indicator: `/tmp/redsocks.ready`

## Files
| File | Description |
|:-----|:------------|
| `__setup_proxy.sh` | Proxy setup and monitoring script (Psiphon + Redsocks + iptables) |
| `Dockerfile` | Ubuntu 24.04-based image |
| `psiphon.config` | Psiphon tunnel core configuration |

## Usage

### 1. Import into your Dockerfile
```dockerfile
FROM ghcr.io/techroy23/docker-psiphon-redsocks:latest

COPY . /app
RUN chmod +x /app/*.sh

ENTRYPOINT ["/app/your_program.sh"]
```

### 2. Run with required capabilities
```bash
docker run -it --rm \
  --sysctl net.ipv4.ip_forward=1 \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  yourimage:latest
```

### 3. In your entrypoint script
```bash
#!/bin/bash
set -e

/app/__setup_proxy.sh &

while [ ! -f /tmp/redsocks.ready ]; do
    sleep 5
done

echo "Proxy ready!"
./your_program
```

## Environment Variables
| Variable | Default | Description |
|:---------|:--------|:------------|
| `SHOW_LOGS` | false | Show Psiphon/Redsocks logs (true/false) |

## How it works
1. **Psiphon** starts and binds a SOCKS5 proxy to `127.0.0.1:1080` and HTTP proxy to `127.0.0.1:8080`
2. **Socat** opens `0.0.0.0:40001` so external hosts can also use Psiphon as a SOCKS5 proxy
3. **Redsocks** listens on `127.0.0.1:50000` and forwards all traffic to Psiphon's SOCKS5
4. **iptables** `OUTPUT` chain redirects all outbound TCP (except localhost, DNS, and proxy ports) to Redsocks
5. A **monitor loop** checks connectivity every 3 minutes and restarts the stack after 3 consecutive failures
6. `/tmp/redsocks.ready` is created once everything is verified working

## Notes
- Requires `NET_ADMIN` and `NET_RAW` capabilities
- First run: Psiphon registers and stores state in the data path (`/tmp/psiphon`)
- The Psiphon binary runs as an unprivileged `psiphon` user
- iptables uses `--uid-owner psiphon` to prevent circular dependency (Psiphon's own traffic bypasses the redirect)

## References
- [Psiphon](https://psiphon.ca)
- [Psiphon Tunnel Core](https://github.com/Psiphon-Labs/psiphon-tunnel-core)
- [Psiphon Tunnel Core Binaries](https://github.com/Psiphon-Labs/psiphon-tunnel-core-binaries)
- [Redsocks](https://github.com/darkk/redsocks)
