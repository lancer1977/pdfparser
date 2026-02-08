FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      poppler-utils \
      inotify-tools \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY watch.sh /app/watch.sh
RUN chmod +x /app/watch.sh

ENTRYPOINT ["/app/watch.sh"]
