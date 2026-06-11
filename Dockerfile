FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      poppler-utils \
      inotify-tools \
      imagemagick \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY watch.sh /app/watch.sh
RUN chmod +x /app/watch.sh

ENTRYPOINT ["/app/watch.sh"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 CMD ["/bin/sh", "-c", "grep -aq '/app/watch.sh' /proc/1/cmdline"]
