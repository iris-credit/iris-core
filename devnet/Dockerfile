# The public door in front of anvil (proxy/): a static binary, tested at build time.
FROM golang:1.25.3-alpine AS proxy
ENV CGO_ENABLED=0
WORKDIR /src
COPY proxy/ .
RUN go vet ./... && go test ./... && go build -trimpath -ldflags="-s -w" -o /devnet-proxy .

# Pinned so Railway rebuilds don't drift anvil behavior; matches the version used locally.
FROM ghcr.io/foundry-rs/foundry:v1.7.1

# Root so anvil can write state to the Railway volume mounted at /data.
USER root

COPY --from=proxy /devnet-proxy /usr/local/bin/devnet-proxy
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
