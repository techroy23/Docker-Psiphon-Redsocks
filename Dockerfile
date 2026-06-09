FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl iptables redsocks \
    coreutils ca-certificates dos2unix socat \
  && rm -rf /var/lib/apt/lists/* \
  && useradd -r -s /usr/sbin/nologin -d /tmp/psiphon psiphon

WORKDIR /app
RUN mkdir -p /app/_psiphon

# Download Psiphon tunnel core binary
RUN curl -fsSL -o /app/_psiphon/psiphon-tunnel-core-x86_64 \
    "https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/refs/heads/master/linux/psiphon-tunnel-core-x86_64" \
  && chmod +x /app/_psiphon/psiphon-tunnel-core-x86_64

# Copy config and setup script
COPY psiphon.config /app/_psiphon/psiphon.config
COPY __setup_proxy.sh /app/__setup_proxy.sh
RUN dos2unix /app/__setup_proxy.sh && chmod +x /app/__setup_proxy.sh

HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
  CMD timeout 3 bash -c 'echo >/dev/tcp/127.0.0.1/1080' 2>/dev/null || exit 1

ENTRYPOINT ["/bin/bash"]