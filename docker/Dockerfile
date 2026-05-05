FROM node:22-bookworm

ARG PUID=1000
ARG PGID=1000

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    coreutils \
    curl \
    git \
    jq \
    less \
    nano \
    openssh-client \
    procps \
    ripgrep \
  && npm install --global opencode-ai \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

COPY hostctl /usr/local/bin/hostctl
RUN chmod +x /usr/local/bin/hostctl

RUN set -eux; \
  if getent group "${PGID}" >/dev/null; then \
    group_name="$(getent group "${PGID}" | cut -d: -f1)"; \
  else \
    groupadd -g "${PGID}" opencode; \
    group_name="opencode"; \
  fi; \
  useradd -m -u "${PUID}" -g "${PGID}" -s /bin/bash opencode; \
  mkdir -p \
    /workspace \
    /home/opencode/.config/opencode \
    /home/opencode/.local/share/opencode \
    /home/opencode/.local/state/opencode \
    /home/opencode/.ssh; \
  chown -R opencode:"${PGID}" /workspace /home/opencode

USER opencode
WORKDIR /workspace

ENTRYPOINT ["opencode"]
CMD ["web", "--hostname", "0.0.0.0", "--port", "4096"]
