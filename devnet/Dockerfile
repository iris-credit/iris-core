FROM ghcr.io/foundry-rs/foundry:stable

# Root so anvil can write state to the Railway volume mounted at /data.
USER root

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
