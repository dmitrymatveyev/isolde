# Applies to login shells and, through startwm.sh, the whole desktop session.
export PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
export BROWSER=chromium

# The base image sets no locale.
export LANG=C.UTF-8 LC_ALL=C.UTF-8

# Claude Code is installed in a root-owned location, so update it by rebuilding.
export DISABLE_AUTOUPDATER=1

# There's no GPU over RDP, and kitty needs OpenGL.
export LIBGL_ALWAYS_SOFTWARE=1
