# Pinned so Railway rebuilds don't drift anvil behavior; matches the version used locally.
FROM ghcr.io/foundry-rs/foundry:v1.7.1

# Root so anvil can write state to the Railway volume mounted at /data.
USER root

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
