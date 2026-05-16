const Applet = imports.ui.applet;
const PopupMenu = imports.ui.popupMenu;
const Mainloop = imports.mainloop;
const GLib = imports.gi.GLib;
const ByteArray = imports.byteArray;

const LOCALHOTKEY = "/home/wantless/.local/bin/localhotkey";

function runSync(command) {
    try {
        let [ok, stdout, stderr, status] = GLib.spawn_command_line_sync(command);
        return {
            ok: ok,
            status: status,
            stdout: stdout ? ByteArray.toString(stdout) : "",
            stderr: stderr ? ByteArray.toString(stderr) : ""
        };
    } catch (e) {
        return {ok: false, status: 1, stdout: "", stderr: String(e)};
    }
}

function runAsync(command) {
    try {
        GLib.spawn_command_line_async(command);
        return true;
    } catch (e) {
        global.logError(e);
        return false;
    }
}

class LocalHotkeyApplet extends Applet.TextIconApplet {
    constructor(metadata, orientation, panelHeight, instanceId) {
        super(orientation, panelHeight, instanceId);

        this.set_applet_icon_symbolic_name("input-keyboard-symbolic");
        this.set_applet_label("LHK");

        this.menuManager = new PopupMenu.PopupMenuManager(this);
        this.menu = new Applet.AppletPopupMenu(this, orientation);
        this.menuManager.addMenu(this.menu);

        this._buildMenu();
        this._refresh();

        this._timer = Mainloop.timeout_add_seconds(5, () => {
            this._refresh();
            return true;
        });
    }

    on_applet_clicked(event) {
        this._refresh();
        this.menu.toggle();
    }

    on_applet_removed_from_panel() {
        if (this._timer) {
            Mainloop.source_remove(this._timer);
            this._timer = null;
        }
    }

    _buildMenu() {
        this.menu.removeAll();

        this.statusItem = new PopupMenu.PopupMenuItem("Status: checking...", {reactive: false});
        this.menu.addMenuItem(this.statusItem);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        this._addCommandItem("Refresh", null, () => this._refresh());
        this._addCommandItem("Start hotkeys", `${LOCALHOTKEY} service start`);
        this._addCommandItem("Restart hotkeys", `${LOCALHOTKEY} service restart`);
        this._addCommandItem("Stop hotkeys", `${LOCALHOTKEY} service stop`);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        this._addCommandItem("Open config", `${LOCALHOTKEY} open config`);
        this._addCommandItem("Open config folder", `${LOCALHOTKEY} open folder`);
        this._addCommandItem("Open source project", `${LOCALHOTKEY} open source`);
        this._addCommandItem("Open service logs", `x-terminal-emulator -e ${LOCALHOTKEY} logs`);
    }

    _addCommandItem(label, command, callback = null) {
        let item = new PopupMenu.PopupMenuItem(label);
        item.connect("activate", () => {
            if (callback) {
                callback();
                return;
            }

            runAsync(command);

            Mainloop.timeout_add(900, () => {
                this._refresh();
                return false;
            });
        });
        this.menu.addMenuItem(item);
    }

    _refresh() {
        let result = runSync(`${LOCALHOTKEY} status-json`);
        let label = "LHK ?";
        let tooltip = "localhotkey status unavailable";
        let statusText = "Status: unavailable";

        if (result.ok && result.stdout) {
            try {
                let data = JSON.parse(result.stdout);
                let running = data.sxhkd_running_generated_config === true;
                let active = data.service ? data.service.active : "unknown";
                let enabled = data.service ? data.service.enabled : "unknown";
                let configValid = data.config_valid === true;

                if (running) {
                    label = "LHK ON";
                } else {
                    label = "LHK OFF";
                }

                tooltip = `localhotkey: ${running ? "running" : "stopped"}; service=${active}; enabled=${enabled}`;
                statusText = `Status: ${running ? "running" : "stopped"} | service=${active} | enabled=${enabled} | config=${configValid ? "valid" : "invalid"}`;

                if (!configValid && data.error) {
                    statusText = `Status: config error: ${data.error}`;
                    tooltip = statusText;
                }
            } catch (e) {
                statusText = "Status: failed to parse localhotkey status";
                tooltip = statusText;
            }
        } else if (result.stderr) {
            statusText = `Status: ${result.stderr.trim()}`;
            tooltip = statusText;
        }

        this.set_applet_label(label);
        this.set_applet_tooltip(tooltip);

        if (this.statusItem) {
            this.statusItem.label.set_text(statusText);
        }
    }
}

function main(metadata, orientation, panelHeight, instanceId) {
    return new LocalHotkeyApplet(metadata, orientation, panelHeight, instanceId);
}
