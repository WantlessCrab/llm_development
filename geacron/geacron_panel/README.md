<!-- README.md -->

# GeaCron Live Map Panel

A host-local Linux Mint Cinnamon/X11 utility for launching the real GeaCron website in a dedicated Chrome app window and
placing it on the top-middle monitor as a live, background-like map surface.

The utility does not inject scripts into GeaCron, crop the site, scrape map data, run Docker, run Electron, start a
local web server, or replace HydraPaper. It launches the live GeaCron page and uses X11 window-manager controls to place
and layer the window.

## Authority

```text
Source/dev authority:
  /home/wantless/PycharmProjects/automation/geacron/geacron_panel

Runtime profile:
  runtime/profile

Runtime logs:
  runtime/logs/panel.log

Configuration authority:
  config/config.toml

Desktop/window authority:
  active X11 session, xrandr monitor geometry, wmctrl window placement
```

## Target monitor

The default target is the top-middle monitor from the local stack contract:

```text
DisplayPort-5 / ONN 100027813
1920x1080 @ 60.00
position +1565+0
```

The config stores this in two places:

```text
window.monitor            active monitor to use
monitor_contract          expected physical target and geometry
```

`desktop` launch mode stops before launching if the configured monitor is missing or if the active xrandr geometry does
not match the monitor contract. This prevents silently launching the map onto the wrong monitor or stale geometry.

## What it does

```text
GeaCron live website
→ dedicated Chrome app window
→ dedicated project-local Chrome profile
→ active xrandr monitor geometry discovery
→ wmctrl move/resize
→ optional background-like X11 hints in desktop mode
```

Desktop mode applies these X11 window states:

```text
below
sticky
skip_taskbar
skip_pager
```

That makes the panel behave like a live background-like monitor surface while preserving GeaCron-native map controls,
date/timeline controls, drag, zoom, and saved/deep links.

## What it does not do

```text
No iframe wrapper
No viewport extension
No page injection
No map scraping
No local GeaCron clone
No Docker service
No Electron shell
No local web server
No HydraPaper replacement
No service/autostart unless explicitly installed by command
```

## Dependencies

```text
Python 3.11+
Google Chrome available as google-chrome unless config changes it
xrandr from x11-xserver-utils
wmctrl
xdotool optional for forced close fallback only
Linux Mint Cinnamon/X11 session
```

## First dry-run workflow

From the project root:

```bash
./scripts/doctor.sh
./scripts/launch.sh --dry-run
python3 scripts/geacron_panel.py status --verbose
```

Expected dry-run result:

```text
Result: OK for launch
plan: 1920x1080+1565+0 on DisplayPort-5
command includes --app=https://geacron.com/home-en/
command includes --user-data-dir=.../runtime/profile
command includes --window-position=1565,0
command includes --window-size=1920,1080
```

If doctor or dry-run reports `STOP`, fix that reported layer first. Do not work around it by changing unrelated files.

## Launch

Default launch uses the configured mode, which is `desktop`:

```bash
./scripts/launch.sh
```

Explicit desktop launch:

```bash
./scripts/launch.sh --mode desktop
```

Plain movable window test:

```bash
./scripts/launch.sh --mode window
```

Temporary saved/deep GeaCron URL:

```bash
./scripts/launch.sh --url 'PASTE-GEACRON-LINK-HERE'
```

## Manage

```bash
python3 scripts/geacron_panel.py status
python3 scripts/geacron_panel.py status --verbose
python3 scripts/geacron_panel.py close
python3 scripts/geacron_panel.py reset-profile
```

## Monitor tools

Show detected monitors and the top-middle suggestion:

```bash
python3 scripts/geacron_panel.py suggest-monitor
```

Write the active detected monitor into config:

```bash
python3 scripts/geacron_panel.py set-monitor DisplayPort-5 --desktop-default
```

`set-monitor` updates the fallback geometry and monitor contract from active xrandr output. Use it only after the
display layout is already correct.

## Desktop launcher pointer

Install a normal application launcher:

```bash
python3 scripts/geacron_panel.py install-desktop
```

Install launcher plus autostart pointer:

```bash
python3 scripts/geacron_panel.py install-desktop --autostart
```

Remove both pointer files:

```bash
python3 scripts/geacron_panel.py remove-desktop
```

## Configuration

Primary file:

```text
config/config.toml
```

Primary controls:

```text
general.url                         default live GeaCron URL or saved link
general.chrome_binary               Chrome executable
general.chrome_extra_args            optional local Chrome flags
general.default_mode                 window or desktop
window.monitor                       target xrandr output
window.desktop_fill_monitor          fill active monitor geometry in desktop mode
window.desktop_fullscreen            optional fullscreen hint; keep false until needed
monitor_contract                     expected top-middle monitor identity and geometry
safety.require_x11                   stop outside X11
safety.require_configured_monitor_for_desktop
safety.require_monitor_contract_match_for_desktop
```

## Success definition

```text
1. doctor reports OK.
2. dry-run reports OK for launch.
3. launch opens the live GeaCron site.
4. GeaCron controls remain native and interactive.
5. status --verbose reports the window and target placement.
6. close removes the panel cleanly.
7. No Docker, browser service, iframe, page injection, or HydraPaper mutation is introduced.
```