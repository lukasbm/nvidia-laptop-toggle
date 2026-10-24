import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const CONFIG = '/etc/nvidia-compute-toggle.conf';
const HELPER = '/usr/local/libexec/nvidia-compute-helper';
const SUDO = '/usr/bin/sudo';

function readText(path) {
    try {
        const [ok, contents] = GLib.file_get_contents(path);
        if (!ok)
            return null;
        return new TextDecoder('utf-8').decode(contents);
    } catch (e) {
        return null;
    }
}

function readConfig() {
    const text = readText(CONFIG);
    if (!text)
        return null;

    const values = {};
    for (const line of text.split('\n')) {
        const match = line.match(/^([A-Z_]+)=(.*)$/);
        if (!match)
            continue;

        let value = match[2].trim();
        if ((value.startsWith("'") && value.endsWith("'")) ||
            (value.startsWith('"') && value.endsWith('"')))
            value = value.slice(1, -1);

        values[match[1]] = value;
    }

    if (!values.DGPU_PCI || !values.DGPU_BRIDGE)
        return null;

    return values;
}

const CudaToggle = GObject.registerClass(
class CudaToggle extends QuickSettings.QuickToggle {
    constructor(extension) {
        super({
            title: 'CUDA',
            subtitle: 'Checking…',
            iconName: 'applications-science-symbolic',
            toggleMode: true,
        });

        this._extension = extension;
        this._busy = false;
        this._config = null;
        this._timeoutId = 0;

        this.connect('clicked', () => this._onClicked());
        this._refresh();
        this._timeoutId = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT, 3, () => {
                this._refresh();
                return GLib.SOURCE_CONTINUE;
            });
    }

    _state() {
        const config = this._config;
        if (!config)
            return 'missing';

        const gpuPath = `/sys/bus/pci/devices/${config.DGPU_PCI}`;
        const bridgePath = `/sys/bus/pci/devices/${config.DGPU_BRIDGE}/power_state`;
        const gpu = GLib.file_test(gpuPath, GLib.FileTest.EXISTS);
        const mod = GLib.file_test('/sys/module/nvidia', GLib.FileTest.EXISTS);

        if (!gpu && !mod) {
            const bridge = readText(bridgePath)?.trim();
            return bridge === 'D3cold' ? 'off' : 'transition';
        }

        if (gpu && mod)
            return 'on';

        return 'transition';
    }

    _refresh() {
        if (this._busy)
            return;

        this._config = readConfig();
        const state = this._state();

        if (state === 'on') {
            this.checked = true;
            this.subtitle = 'On';
            this.reactive = true;
        } else if (state === 'off') {
            this.checked = false;
            this.subtitle = 'Off';
            this.reactive = true;
        } else if (state === 'missing') {
            this.checked = false;
            this.subtitle = 'Not installed';
            this.reactive = false;
        } else {
            this.subtitle = 'Transition';
            this.reactive = true;
        }
    }

    _onClicked() {
        if (this._busy)
            return;

        if (!this._config)
            this._config = readConfig();

        if (!this._config) {
            Main.notify('CUDA', 'nvidia-compute-toggle is not installed');
            this._refresh();
            return;
        }

        // Use the actual sysfs state, not the already-toggled switch, so a
        // failed command still reverts to the correct position. If the GPU or
        // module is present in an intermediate state, prefer cleaning up.
        const state = this._state();
        const gpu = GLib.file_test(
            `/sys/bus/pci/devices/${this._config.DGPU_PCI}`,
            GLib.FileTest.EXISTS);
        const mod = GLib.file_test('/sys/module/nvidia', GLib.FileTest.EXISTS);
        const action = (state === 'on' || gpu || mod) ? 'off' : 'on';

        this._busy = true;
        this.reactive = false;
        this.subtitle = action === 'on' ? 'Starting…' : 'Stopping…';

        let proc;
        try {
            proc = Gio.Subprocess.new(
                [SUDO, '-n', HELPER, action],
                Gio.SubprocessFlags.STDOUT_PIPE |
                Gio.SubprocessFlags.STDERR_PIPE);
        } catch (e) {
            this._finish(action, false, e.message);
            return;
        }

        proc.communicate_utf8_async(null, null, (p, res) => {
            let stdout = '';
            let stderr = '';
            try {
                [, stdout, stderr] = p.communicate_utf8_finish(res);
            } catch (e) {
                stderr = e.message;
            }
            this._finish(action, p.get_successful(), (stderr || stdout || '').trim());
        });
    }

    _finish(action, ok, detail) {
        this._busy = false;
        this.reactive = true;

        if (!ok) {
            const message = detail || `Could not turn CUDA ${action}`;
            Main.notify('CUDA toggle failed', message);
        }

        this._refresh();
    }

    destroy() {
        if (this._timeoutId) {
            GLib.source_remove(this._timeoutId);
            this._timeoutId = 0;
        }
        super.destroy();
    }
});

const CudaIndicator = GObject.registerClass(
class CudaIndicator extends QuickSettings.SystemIndicator {
    constructor(extension) {
        super();
        this.quickSettingsItems.push(new CudaToggle(extension));
    }

    destroy() {
        this.quickSettingsItems.forEach(item => item.destroy());
        super.destroy();
    }
});

export default class NvidiaComputeToggleExtension extends Extension {
    enable() {
        this._indicator = new CudaIndicator(this);
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
