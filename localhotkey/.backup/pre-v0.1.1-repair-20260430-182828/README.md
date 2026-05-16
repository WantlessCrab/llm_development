# localhotkey

`localhotkey` is a lightweight user-local automation app for Linux Mint Cinnamon/X11.

Version 0.1.1 uses:

- `sxhkd` for global hotkey capture
- `xclip` for clipboard read/write
- `xdotool` for synthetic paste
- `~/.config/localhotkey/config.yaml` as the single user-facing config authority
- `~/.config/localhotkey/generated.sxhkdrc` as a generated adapter file
- an optional Cinnamon panel applet as a status/control surface

## Authority model

```text
Source project:
  ~/PycharmProjects/automation/localhotkey

Installed app runtime:
  ~/.local/share/localhotkey
  ~/.local/bin/localhotkey

User config authority:
  ~/.config/localhotkey/config.yaml

Generated hotkey backend config:
  ~/.config/localhotkey/generated.sxhkdrc

Optional Cinnamon applet:
  ~/.local/share/cinnamon/applets/localhotkey@wantless
```

The Cinnamon applet is not the config authority. It only displays status and runs `localhotkey` commands.

## Install

From the project root:

```bash
./install.sh
```

Enable the systemd user service:

```bash
./install.sh --enable-service
```

Install the Cinnamon panel applet files:

```bash
./install.sh --install-applet
```

Recommended setup:

```bash
./install.sh --enable-service --install-applet
```

Then add the applet through Cinnamon:

```text
Right-click panel → Applets → Manage → localhotkey → Add
```

## Core commands

```bash
localhotkey doctor
localhotkey status
localhotkey status-json
localhotkey render
localhotkey wrap fenced_text
localhotkey run wrap_fenced_text
localhotkey service status
localhotkey service restart
localhotkey open config
localhotkey open folder
localhotkey logs
```

## Normal edit cycle

1. Edit:

```text
~/.config/localhotkey/config.yaml
```

2. Validate/render:

```bash
localhotkey doctor
localhotkey render
```

3. Restart hotkey backend:

```bash
localhotkey service restart
```

## Manual foreground hotkey test

```bash
sxhkd -c "$HOME/.config/localhotkey/generated.sxhkdrc"
```

Stop with `Ctrl+C`.

## Current v0.1 wrapper bindings

```text
Ctrl+Shift+1 -> fenced Markdown text block
Ctrl+Shift+2 -> Markdown inline code
Ctrl+Shift+3 -> double quotes
Ctrl+Shift+4 -> XML context block
Ctrl+Shift+5 -> Markdown quote block
```
