#!/bin/sh
set -e
: "${RDP_PASSWORD:?RDP_PASSWORD must be set}"
echo "dev:$RDP_PASSWORD" | chpasswd
unset RDP_PASSWORD

# Add files from the image that are missing from this home. Never overwrites.
su dev -c 'cp -a --update=none /opt/home-seed/. /home/dev/'

mkdir -p /run/dbus
dbus-daemon --system
/usr/sbin/xrdp-sesman
exec /usr/sbin/xrdp --nodaemon
