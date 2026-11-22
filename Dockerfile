FROM ubuntu:24.04

ARG HOST_UID=1000
ARG HOST_GID=1000

RUN apt-get update && apt-get install -y \
      xrdp xorgxrdp xfce4 xfce4-terminal dbus-x11 sudo \
    && rm -rf /var/lib/apt/lists/*

# Match the host user so files in /workspace have the right owner.
# If an image user already has that UID, move it to a free one first.
RUN groupadd -o -g "$HOST_GID" dev \
    && existing=$(getent passwd "$HOST_UID" | cut -d: -f1) \
    && if [ -n "$existing" ]; then usermod -u 59999 "$existing"; fi \
    && useradd -m -s /bin/bash -u "$HOST_UID" -g dev -G sudo dev \
    && adduser xrdp ssl-cert

# Allow a non-console user to start Xorg, and start XFCE on login.
# Sourcing /etc/profile makes /etc/profile.d settings apply to the whole session.
RUN echo 'allowed_users=anybody' > /etc/X11/Xwrapper.config \
    && printf '#!/bin/sh\nunset DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR\n. /etc/profile\nexec startxfce4\n' \
       > /etc/xrdp/startwm.sh \
    && chmod +x /etc/xrdp/startwm.sh

# Desktop defaults and environment settings
COPY rootfs/ /

# kitty, Node.js, and the tools Claude Code commonly uses
RUN apt-get update && apt-get install -y \
      kitty kitty-terminfo ncurses-term tmux curl ca-certificates git gh ripgrep fd-find jq unzip less \
      openssh-client procps python3 build-essential \
    && update-alternatives --install /usr/bin/x-terminal-emulator \
       x-terminal-emulator /usr/bin/kitty 100 \
    && curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Claude Code and Playwright. Ubuntu's chromium-browser package needs snap, which
# doesn't work in a container, so the desktop uses Playwright's Chromium.
# dev owns the browser directory so that projects can install other versions.
ARG PLAYWRIGHT_VERSION=1.64.1
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN npm install -g @anthropic-ai/claude-code "playwright@$PLAYWRIGHT_VERSION" \
    && playwright install --with-deps chromium \
    && chromium_bin=$(find /opt/ms-playwright -type f -name chrome -path '*/chromium-*' | head -n 1) \
    && test -n "$chromium_bin" \
    && printf '#!/bin/sh\nif [ "$ISOLDE_CHROMIUM_NO_SANDBOX" = 1 ]; then set -- --no-sandbox "$@"; fi\nexec %s "$@"\n' "$chromium_bin" > /usr/local/bin/chromium \
    && chmod +x /usr/local/bin/chromium \
    && chown -R dev:dev /opt/ms-playwright \
    && rm -rf /var/lib/apt/lists/*

# Google Chrome, for the Claude in Chrome extension. Google only publishes this
# package for amd64, so other architectures skip it and keep just Chromium.
# The package also adds Google's apt repository and signing key.
RUN if [ "$(dpkg --print-architecture)" = amd64 ]; then \
      curl -fsSLo /tmp/google-chrome.deb \
        https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
      && apt-get update \
      && apt-get install -y /tmp/google-chrome.deb \
      && rm -rf /tmp/google-chrome.deb /var/lib/apt/lists/*; \
    else \
      echo "Skipping Google Chrome: no package for $(dpkg --print-architecture)"; \
    fi

# Ansible, for managing servers such as matrix-docker-ansible-deploy setups.
# Ubuntu's community.docker 3.7.0 doesn't work with Debian 13 hosts, and 5.x
# needs ansible-core 2.17 or later, so install 4.x where all users can see it.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ansible pwgen just \
    && rm -rf /var/lib/apt/lists/*

# Ansible Galaxy downloads often time out, so wait longer and retry.
RUN for attempt in 1 2 3; do \
      ansible-galaxy collection install --timeout 120 \
        -p /usr/share/ansible/collections 'community.docker:>=4.0.0,<5.0.0' \
        && exit 0; \
      echo "Galaxy download failed (attempt $attempt), retrying in 10 seconds"; \
      sleep 10; \
    done; \
    exit 1

# Install other apps here. Prefer system paths, and set PATH in /etc/profile.d.
# Apps that must install into ~ should run as the dev user:
#   USER dev
#   RUN curl -fsSL https://example.com/install.sh | sh
#   USER root

# Keep this after all steps that write to /home/dev. The home volume hides
# /home/dev, so entrypoint.sh uses this copy to add files missing from it.
RUN cp -a /home/dev /opt/home-seed

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 3389
ENTRYPOINT ["/entrypoint.sh"]
