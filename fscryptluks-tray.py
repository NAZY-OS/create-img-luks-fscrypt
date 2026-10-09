#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# fscrypt-opener GTK4 Tray Indicator (Unprivileged User GUI)
# Licensed under GNU GPL v3

import sys
import os
import json
import subprocess
import gi

gi.require_version('Gtk', '4.0')
gi.require_version('Gio', '2.0')
gi.require_version('AyatanaAppIndicator3', '0.1')

from gi.repository import Gtk, Gio, GLib, AyatanaAppIndicator3 as AppIndicator

APP_ID = "org.gnu.fscrypt.opener"
BACKEND_SCRIPT = "/usr/local/bin/fscrypt-opener.sh"
UPDATE_INTERVAL_SEC = 2

ICON_DATA = {
    "green": '<svg width="16" height="16"><circle cx="8" cy="8" r="7" fill="#2ec27e" stroke="#1a8553" stroke-width="1"/></svg>',
    "orange": '<svg width="16" height="16"><circle cx="8" cy="8" r="7" fill="#ff7800" stroke="#c64600" stroke-width="1"/></svg>',
    "red": '<svg width="16" height="16"><circle cx="8" cy="8" r="7" fill="#ed333b" stroke="#a51d2d" stroke-width="1"/></svg>'
}
TEMP_ICON_DIR = "/tmp/fscrypt_tray_icons"

def ensure_icons_exist():
    try:
        if not os.path.exists(TEMP_ICON_DIR):
            os.makedirs(TEMP_ICON_DIR)
        for color, data in ICON_DATA.items():
            path = os.path.join(TEMP_ICON_DIR, f"dot_{color}.svg")
            if not os.path.exists(path):
                with open(path, "w") as f:
                    f.write(data)
        return True
    except OSError:
        return False

def send_notification(title, msg, urgent=False):
    notification = Gio.Notification.new(title)
    notification.set_body(msg)
    if urgent:
        notification.set_priority(Gio.NotificationPriority.URGENT)
    notification.set_icon(Gio.ThemedIcon.new("security-high-symbolic"))
    app = Gio.Application.get_default()
    if app:
        app.send_notification(None, notification)

def get_backend_status():
    try:
        proc = subprocess.run([BACKEND_SCRIPT, "api_status"], capture_output=True, text=True, check=True)
        return json.loads(proc.stdout)
    except Exception:
        return None

class FscryptOptionsWindow(Gtk.Window):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.set_title("Fscrypt Persistent Settings")
        self.set_default_size(350, 200)

        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        vbox.set_margin_start(16)
        vbox.set_margin_end(16)
        vbox.set_margin_top(16)
        vbox.set_margin_bottom(16)
        self.set_child(vbox)

        lbl = Gtk.Label(label="<b>Default Auto-Close Timeout (Minutes)</b>")
        lbl.set_use_markup(True)
        vbox.append(lbl)

        self.entry_autolock = Gtk.Entry()
        self.entry_autolock.set_placeholder_text("Minutes (e.g. 10)")
        vbox.append(self.entry_autolock)

        save_btn = Gtk.Button(label="Save to Config")
        save_btn.connect("clicked", self.on_save_clicked)
        vbox.append(save_btn)

    def on_save_clicked(self, button):
        val = self.entry_autolock.get_text()
        if val.isdigit():
            subprocess.run([BACKEND_SCRIPT, "api_save_setting", "DEFAULT_AUTOLOCK", val])
            send_notification("Fscrypt Config", f"Default auto-close set to {val} minutes.")
            self.close()
        else:
            send_notification("Fscrypt Error", "Please enter a valid number.", urgent=True)

class FscryptTrayApp(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.FLAGS_NONE)
        self.indicator = None
        self.settings_window = None
        self.is_blinking = False
        self.blink_state = False
        self.notified_folders = set()

    def do_activate(self):
        if not ensure_icons_exist():
            self.quit()
            return

        self.indicator = AppIndicator.Indicator.new(
            APP_ID,
            os.path.join(TEMP_ICON_DIR, "dot_red.svg"),
            AppIndicator.IndicatorCategory.SYSTEM_SERVICES
        )
        self.indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)
        
        self.update_ui()
        GLib.timeout_add_seconds(UPDATE_INTERVAL_SEC, self.update_ui)
        GLib.timeout_add(500, self.check_blink)

    def update_ui(self):
        status_data = get_backend_status()
        if not status_data:
            self.set_icon_color("red")
            self.build_error_menu()
            return True

        self.analyze_global_state(status_data)
        self.build_dynamic_menu(status_data)
        return True

    def set_icon_color(self, color):
        if self.indicator:
            path = os.path.join(TEMP_ICON_DIR, f"dot_{color}.svg")
            self.indicator.set_icon_full(path, f"Status: {color}")

    def analyze_global_state(self, data):
        if data.get("luks_locked", True):
            self.set_icon_color("red")
            self.is_blinking = False
            return

        imminent = False
        for folder in data.get("fscrypt_folders", []):
            name = folder.get("name")
            rem = folder.get("remaining_time_sec", -1)
            
            if 0 < rem < 120:
                imminent = True
                if name not in self.notified_folders:
                    send_notification("Auto-Close Warning", f"Encrypted folder '{name}' locks in {rem} seconds!", urgent=True)
                    self.notified_folders.add(name)
            elif rem > 120 and name in self.notified_folders:
                self.notified_folders.remove(name)

        self.is_blinking = imminent
        if not imminent:
            self.set_icon_color("green")

    def check_blink(self):
        if self.is_blinking:
            self.blink_state = not self.blink_state
            self.set_icon_color("orange" if self.blink_state else "red")
        return True

    def execute_backend_action(self, action, target=""):
        try:
            cmd = ["pkexec", BACKEND_SCRIPT, action]
            if target:
                cmd.append(target)
            subprocess.run(cmd, check=True)
            send_notification("Fscrypt", f"Action {action} completed.")
        except subprocess.CalledProcessError as e:
            send_notification("Fscrypt Error", f"Execution failed: {e}", urgent=True)
        self.update_ui()

    def create_menu_item(self, text, color):
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        img = Gtk.Image.new_from_file(os.path.join(TEMP_ICON_DIR, f"dot_{color}.svg"))
        box.append(img)
        box.append(Gtk.Label(label=text))
        item = Gtk.MenuItem()
        item.set_child(box)
        return item

    def build_dynamic_menu(self, data):
        menu = Gtk.Menu()
        luks_locked = data.get("luks_locked", True)
        
        # 1. Main container action
        if luks_locked:
            open_item = Gtk.MenuItem(label="Open Container (LUKS)")
            open_item.connect("activate", lambda w: self.execute_backend_action("api_open"))
            menu.append(open_item)
        else:
            close_item = Gtk.MenuItem(label="Close Container (Umount)")
            close_item.connect("activate", lambda w: self.execute_backend_action("api_close"))
            menu.append(close_item)

        menu.append(Gtk.SeparatorMenuItem())

        # 2. Fscrypt Folders List & individual actions
        for folder in data.get("fscrypt_folders", []):
            name = folder.get("name")
            locked = folder.get("locked")
            rem = folder.get("remaining_time_sec", -1)
            
            color = "green" if not locked else "red"
            if 0 < rem < 120:
                color = "orange"
                
            time_txt = f" ({rem}s)" if 0 < rem < 99999 else ""
            f_item = self.create_menu_item(f"FS: {name}{time_txt}", color)
            
            sub = Gtk.Menu()
            if locked:
                unlock_sub = Gtk.MenuItem(label="Decrypt / Unlock")
                unlock_sub.connect("activate", lambda w, n=name: self.execute_backend_action("api_unlock_folder", n))
                sub.append(unlock_sub)
            else:
                lock_sub = Gtk.MenuItem(label="Lock Immediately")
                lock_sub.connect("activate", lambda w, n=name: self.execute_backend_action("api_lock_folder", n))
                sub.append(lock_sub)
            
            f_item.set_submenu(sub)
            menu.append(f_item)

        menu.append(Gtk.SeparatorMenuItem())

        # 3. Persistent Settings
        opt_item = Gtk.MenuItem(label="Persistent Settings...")
        opt_item.connect("activate", self.open_settings_window)
        menu.append(opt_item)

        # 4. Quit
        quit_item = Gtk.MenuItem(label="Quit")
        quit_item.connect("activate", lambda w: self.quit())
        menu.append(quit_item)

        if self.indicator:
            self.indicator.set_menu(menu)
            menu.show_all()

    def open_settings_window(self, widget):
        if not self.settings_window:
            self.settings_window = FscryptOptionsWindow()
            self.settings_window.connect("destroy", lambda w: setattr(self, 'settings_window', None))
        self.settings_window.present()

    def build_error_menu(self):
        menu = Gtk.Menu()
        err_item = Gtk.MenuItem(label="Backend Unreachable")
        err_item.set_sensitive(False)
        menu.append(err_item)
        menu.append(Gtk.SeparatorMenuItem())
        quit_item = Gtk.MenuItem(label="Quit")
        quit_item.connect("activate", lambda w: self.quit())
        menu.append(quit_item)
        if self.indicator:
            self.indicator.set_menu(menu)
            menu.show_all()

def main():
    app = FscryptTrayApp()
    return app.run(sys.argv)

if __name__ == "__main__":
    sys.exit(main())
