# isolde

Per-project Linux desktop in Docker, reached over RDP. Each project directory gets its own persistent home, and the image includes Claude Code, kitty, tmux, Chromium and Playwright.

- The current directory is mounted at `/workspace`.
- Each directory gets its own home at `/home/dev`, which survives rebuilds.
- The desktop is XFCE on Ubuntu 24.04, served by xrdp.

## Requirements

- Docker
- An RDP client
- `bash` and `sha256sum` on the host

**Tested on:** only the author's Linux machine so far. Other setups, such as Docker Desktop on macOS or Windows, ARM hosts, or Ubuntu hosts that restrict user namespaces, haven't been tried.

## Setup

Build the image from this directory. The build arguments give the container user your host UID and GID, so files in `/workspace` have the right owner.

```bash
docker build --build-arg HOST_UID=$(id -u) --build-arg HOST_GID=$(id -g) -t isolde .
```

Then put the `isolde` script on your `PATH`, for example:

```bash
ln -s "$PWD/isolde" ~/.local/bin/isolde
```

## Usage

Start a container from the directory you want to work in:

```bash
cd ~/projects/foo
export RDP_PASSWORD='choose-something'
isolde
```

The script prints the address to connect to:

```
/home/you/projects/foo -> RDP at 127.0.0.1:49153 (user: dev)
```

Connect your RDP client to that address and log in as `dev` with your `RDP_PASSWORD`. Choose the `Xorg` session if prompted.

Running `isolde` again in the same directory prints the address of the running container. The address can change each time the container starts.

### Open a shell

Run this from the project directory to open a shell in `/workspace` without using RDP:

```bash
isolde shell
```

If the container isn't running, this starts it first, which requires `RDP_PASSWORD` to be set. Typing `exit` closes the shell, and the container keeps running.

The shell uses your terminal's `TERM` and `COLORTERM` settings, so colors match your terminal.

### Stop a container

Container names are also printed by `docker ps`.

```bash
docker stop isolde-<name>-<hash>
```

To stop it from inside the RDP session, open a terminal and run the command below. When `sudo` asks for a password, use your `RDP_PASSWORD`.

```bash
sudo kill 1
```

The RDP connection drops straight away, and unsaved work in open apps is lost. `/workspace` and your home are kept.

Logging out of XFCE only ends the desktop session, so the container keeps running. XFCE's **Shut Down** option won't stop the container either.

### Apply a rebuilt image

Stop the container, rebuild the image, then run `isolde` again. A running container keeps using the old image.

### Update Claude Code

A plain `docker build` doesn't update Claude Code, because Docker reuses the cached npm step. Use `--no-cache` instead. Your homes are stored in volumes, so a rebuild doesn't affect them.

1. Stop all running containers. They'd otherwise keep using the old image.

   ```bash
   docker ps -q --filter 'name=^isolde-' | xargs -r docker stop
   ```

2. Rebuild from the directory containing the `Dockerfile`. `--no-cache` reruns every step, so npm installs the latest Claude Code, and `--pull` fetches the latest base image.

   ```bash
   docker build --no-cache --pull --build-arg HOST_UID=$(id -u) --build-arg HOST_GID=$(id -g) -t isolde .
   ```

3. Check the installed version:

   ```bash
   docker run --rm --entrypoint claude isolde --version
   ```

4. Run `isolde` from your project directory.

This takes as long as the first build, and it also updates the `apt` packages and Node.js. Playwright stays at the version set by `PLAYWRIGHT_VERSION`.

### List homes

```bash
docker volume ls -f label=isolde.path --format '{{.Name}} {{.Label "isolde.path"}}'
```

### Delete a home

Stop its container first. This permanently deletes everything in that home.

```bash
docker volume rm isolde-<name>-<hash>
```

## How it works

| Path in the container | Backed by | Lifetime |
|---|---|---|
| `/workspace` | The directory you ran `isolde` from | Lives on the host |
| `/home/dev` | A named volume, `isolde-<directory name>-<hash of the full path>` | Kept until you delete the volume |
| Everything else | The container | Lost when the container stops |

Docker fills a new, empty volume from the image's `/home/dev`. After that, `entrypoint.sh` copies any files missing from the home out of `/opt/home-seed` each time the container starts. It never overwrites existing files.

## Included apps

| App | Notes |
|---|---|
| kitty | The default terminal. It uses software rendering because RDP has no GPU. `xfce4-terminal` is also installed as a fallback. |
| Claude Code | Installed with npm. Run `claude` and log in. Login is stored in the home, so you log in once per project directory. To update it, see [Update Claude Code](#update-claude-code). |
| Chromium | The default browser, using the copy installed by Playwright. Run `chromium` or use the applications menu. |
| Playwright | Node.js 24 with a global `playwright` command. To use a different version, change `PLAYWRIGHT_VERSION` with `--build-arg`. |

Common tools are also installed: `git`, `gh`, `ripgrep`, `fd-find` (run as `fdfind`), `jq`, `curl`, `unzip`, `tmux`, `openssh-client`, `python3` and `build-essential`.

If a project pins a different Playwright version, run `npx playwright install chromium` in that project. Those browsers are lost when the container stops, so you'd need to install them again. To avoid this, build the image with the project's version.

### tmux

`/etc/tmux.conf` sets tmux up for Claude Code:

- **Color:** full color stays on inside tmux, including Claude Code's selection highlighting.
- **Shift+Enter:** tmux passes Shift+Enter through separately from Enter, so Claude Code inserts a newline. Ctrl+J also inserts a newline in any terminal.
- **Notifications:** `allow-passthrough` and `focus-events` let Claude Code's notifications reach kitty. To turn them on, set `preferredNotifChannel` to `"kitty"` with `/config` or in `~/.claude/settings.json`, once per project directory. A pane in a tmux window you aren't viewing doesn't send notifications.

`allow-passthrough` lets any program in tmux send control sequences straight to your terminal, not just Claude Code. Be careful displaying untrusted output in tmux, such as printing a downloaded file.

tmux sessions survive closing `isolde shell` or disconnecting from RDP, so you can reattach with `tmux attach`. They end when the container stops.

## Chromium sandbox

`isolde` starts containers with `seccomp_profile.json`, which is Docker's default profile plus one rule allowing `clone`, `setns` and `unshare`. Chromium's sandbox needs these calls to create user namespaces. The file has to stay next to the `isolde` script. It's based on Docker's profile from the [Moby project](https://github.com/moby/profiles), licensed under Apache-2.0 (see `NOTICE`).

To check the sandbox, open `chrome://sandbox` in Chromium.

If Chromium won't start and reports that there's no usable sandbox, run this in the container:

```bash
unshare --user --map-root-user true && echo ok
```

If that fails, something on the host is probably blocking user namespaces. Ubuntu 23.10 and later can do this through AppArmor, which you can check on the host:

```bash
sysctl kernel.apparmor_restrict_unprivileged_userns
```

You can run Chromium without its sandbox from a terminal, but only for sites you trust, and not with logged-in accounts you care about:

```bash
ISOLDE_CHROMIUM_NO_SANDBOX=1 chromium
```

Browsers that Playwright launches itself run without the sandbox by default. The steps in the next section avoid this by connecting to the `chromium` window you started.

## Using web portals with Claude Code

Playwright starts with a temporary profile, so it can't see logins from your normal Chromium window. To share them, have Claude Code connect to a logged-in window.

1. In a terminal in the RDP session, start Chromium with a dedicated profile and a debugging port:

   ```bash
   chromium --user-data-dir="$HOME/.config/claude-browser" --remote-debugging-port=9222
   ```

2. Log in to your portals in that window, including any MFA.

3. Give Claude Code browser tools with Playwright MCP. You only need to do this once per home:

   ```bash
   claude mcp add playwright -- npx @playwright/mcp@latest --cdp-endpoint http://localhost:9222
   ```

4. Start `claude` and ask it to use the portal. Leave the window open so you can watch and step in for a CAPTCHA or expired session.

The dedicated profile limits Claude Code to the sites you logged in to there. Recent Chrome versions also restrict remote debugging on the default profile, which may affect Chromium too. Each project directory has its own home, so each one needs its own login.

To work without a visible window, Playwright can save a login to a file with `storageState`. Keep that file out of `/workspace` because it contains live session tokens, and expect to log in again when sessions expire.

### Risks

- **Full account access:** Claude Code can do anything you could do in those portals. Keep it away from sites where a mistake would be costly, such as banking or admin consoles.
- **Malicious page content:** text on a web page can try to give Claude Code instructions (prompt injection). Keep permission prompts on, and review anything that submits, pays or deletes.
- **Open debugging port:** anything running in the container can control the browser while the port is open, so close the window when you've finished.
- **Saved logins:** the profile is stored in the project's home volume, so anyone with access to the Docker host could read those sessions.
- **Portal rules:** some portals prohibit or block automated access, so check their terms.

## Adding apps

Add apps to the `Dockerfile` at the marked spot, above the `cp -a /home/dev /opt/home-seed` line. Anything installed into `~` after that line won't reach existing homes.

Install outside `~` if the app allows it, and set `PATH` in `/etc/profile.d`:

```dockerfile
RUN echo 'export PATH=/opt/myapp/bin:$PATH' > /etc/profile.d/myapp.sh
```

Don't use Docker's `ENV` to set `PATH` for the desktop session, because xrdp sessions don't reliably inherit it.

If an app has to install into `~`, run its installer as `dev`:

```dockerfile
USER dev
RUN curl -fsSL https://example.com/install.sh | sh
USER root
```

Existing homes receive the app's new files on the next start, but not changes to files they already have. This means:

- App upgrades may not fully reach existing homes.
- Lines an installer adds to `~/.bashrc` won't reach existing homes, so set `PATH` in `/etc/profile.d` instead.

## Limitations

- **Only two locations persist:** packages installed with `apt` at runtime are lost when the container stops. Add them to the `Dockerfile` instead.
- **Homes are tied to the path:** renaming or moving a directory gives it a new, empty home. The old volume stays until you delete it.
- **Pruning can delete homes:** `docker volume prune -a` removes all unused named volumes, including the homes of stopped containers.

## Security

isolde is for running your own tools on your own machine. It keeps projects apart from each other, but it isn't a strong security boundary.

- **The password is visible on the host:** `RDP_PASSWORD` is stored in the container's settings, so anyone who can run `docker inspect` can read it. Anyone with Docker access can control the host anyway, but don't reuse a password from elsewhere.
- **The password also unlocks `sudo`:** the `dev` user has full root access inside the container.
- **Programs can change your project:** anything running in the container, including Claude Code, can read and change the mounted project directory and that project's home, and has full network access.
- **Ports are local only:** RDP, and Chromium's debugging port if you open it, can only be reached from the host. xrdp uses a self-signed certificate, so your RDP client will warn about it. For remote access, use an SSH tunnel as described below.
- **Chromium's sandbox depends on the seccomp profile:** see [Chromium sandbox](#chromium-sandbox). If you use logged-in portals with Claude Code, read [Risks](#risks).
- **tmux passes control sequences through:** see [tmux](#tmux).

## Remote access

The RDP port is bound to `127.0.0.1`, so it can only be reached from the host. To connect from another machine, use an SSH tunnel instead of exposing the port:

```bash
ssh -L 3389:127.0.0.1:<port> user@host
```

Then connect your RDP client to `127.0.0.1:3389`.

## License

Apache License 2.0. See `LICENSE` and `NOTICE`.
