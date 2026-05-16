# localhotkey operating model

## what it can do so far

1. Bind global hotkeys through sxhkd
   Example: Ctrl+Shift+1, Ctrl+Shift+2, etc.
2. Run named actions from config.yaml
   Hotkeys point to action names, not hardcoded commands.
3. Wrap clipboard text
   before + clipboard + after
   optional line prefix
   optional transform: none, strip, lstrip, rstrip
4. Paste into the active X11 window
   Uses xdotool to send configured paste key, currently ctrl+v.
5. Restore original clipboard after paste
   The wrapped clipboard is temporary; original clipboard returns after restore_delay_ms.
6. Run arbitrary command actions
   The config supports action type: command with argv list.
7. Generate sxhkd config from one canonical config
   config.yaml is the authority.
   generated.sxhkdrc is only an adapter artifact.
8. Validate environment and runtime state
   localhotkey doctor checks X11, DISPLAY, XAUTHORITY, sxhkd, xclip, xdotool, systemd, config parse, service state, and
   active sxhkd backend.
9. Report human-readable and machine-readable status
   localhotkey status
   localhotkey status-json
10. Control its service
    localhotkey service start|stop|restart|enable|disable|status
11. Open its working surfaces
    localhotkey open config
    localhotkey open folder
    localhotkey open generated
    localhotkey open source
12. Integrate with Cinnamon panel
    Applet can show LHK ON/OFF and provide control shortcuts.

```text
sxhkd
  Captures global X11 hotkeys.
  Reads generated.sxhkdrc.
  Starts/stops with the user session.

localhotkey
  Executes named actions.
  Reads config.yaml.
  Generates sxhkdrc.
  Validates active state.
  Controls the systemd user service.

config.yaml
  Single source of user intent.
  Defines bindings, actions, wrappers, and backend options.

generated.sxhkdrc
  Backend adapter file.
  Generated from config.yaml.
  Not manually edited.

Cinnamon applet
  Status/control surface only.
  Calls localhotkey status-json and localhotkey service commands.
  Does not own config.
```

## Failure-layer separation

```text
Hotkey does nothing:
  sxhkd/service/applet/autostart layer.

Command works but hotkey fails:
  sxhkd generated config or session startup layer.

localhotkey wrap fails:
  app/config/clipboard/paste layer.

Paste occurs but wrong content:
  wrapper config or clipboard restore timing.

Paste occurs in wrong active window:
  focus/runtime GUI state, not config parse or sxhkd syntax.

Applet says OFF:
  service stopped, sxhkd not running generated config, or status check cannot read app state.
```