# localhotkey

`localhotkey` is a lightweight user-local automation app for Linux Mint Cinnamon/X11.

Version 0.1 uses:

- `sxhkd` for global hotkey capture
- `xclip` for clipboard read/write
- `xdotool` for synthetic paste
- `~/.config/localhotkey/config.yaml` as the single user-facing config authority
- `~/.config/localhotkey/generated.sxhkdrc` as a generated adapter file

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

Session startup:
  ~/.config/systemd/user/localhotkey.service
  or
  ~/.config/autostart/localhotkey.desktop
```

## Install

From the project root:

```bash
./install.sh
```

This installs the app into user-local locations, copies the example config if no active config exists, renders the generated `sxhkdrc`, and installs service/autostart templates.

To enable systemd user service startup:

```bash
./install.sh --enable-service
```

To use Cinnamon autostart instead:

```bash
./install.sh --enable-autostart
```

Use one startup method, not both.

## Core commands

```bash
localhotkey doctor
localhotkey status
localhotkey render
localhotkey wrap fenced_text
localhotkey run wrap_fenced_text
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

3. Restart startup backend if needed:

```bash
systemctl --user restart localhotkey.service
```

or log out/back in if using Cinnamon autostart.

## Manual foreground hotkey test

```bash
sxhkd -c "$HOME/.config/localhotkey/generated.sxhkdrc"
```

Stop with `Ctrl+C`.

## Current v0.1 behavior

The shipped config binds:

```text
Ctrl+Shift+1 -> fenced Markdown text block
Ctrl+Shift+2 -> Markdown inline code
Ctrl+Shift+3 -> double quotes
Ctrl+Shift+4 -> XML context block
Ctrl+Shift+5 -> Markdown quote block
```

The wrapper action:

1. Reads current clipboard.
2. Builds wrapped text.
3. Temporarily replaces the clipboard.
4. Sends the configured paste key to the active X11 window.
5. Restores the original clipboard if configured.
