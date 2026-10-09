def on_toggle_folder(self, btn, fpath, locked, method):
        if locked:
            key_file = ""
            # 1. Wenn die Methode 'raw_key' ist, Key-Datei über Gtk.FileDialog auswählen
            if method == "raw_key":
                dialog = Gtk.FileDialog(title="Schlüsseldatei auswählen (Raw Key)")
                dialog.open(self, None, lambda source, result: self.on_key_file_selected(source, result, fpath, method))
                return  # Warten auf den Callback der Dateiauswahl
            
            # Wenn kein raw_key, direkt den Autoclose-Dialog öffnen
            self.prompt_autoclose_and_unlock(fpath, method, key_file)
        else:
            if self.proxy:
                code = self.proxy.LockFolder(fpath)
                if code != 0:
                    print("Sperren fehlgeschlagen.")
            self.refresh_status()

    def on_key_file_selected(self, dialog, result, fpath, method):
        try:
            gfile = dialog.open_finish(result)
            if gfile:
                key_file = gfile.get_path()
                self.prompt_autoclose_and_unlock(fpath, method, key_file)
        except Exception as e:
            print(f"Auswahl abgebrochen oder Fehler: {e}")

    def prompt_autoclose_and_unlock(self, fpath, method, key_file):
        # 2. Kleiner Dialog für die Autoclose-Minuten
        dialog = Gtk.Dialog(title="Autoclose konfigurieren", transient_for=self, modal=True)
        dialog.add_button("Abbrechen", Gtk.ResponseType.CANCEL)
        dialog.add_button("Entsperren", Gtk.ResponseType.OK)

        content_area = dialog.get_content_area()
        content_area.set_margin_top(12)
        content_area.set_margin_bottom(12)
        content_area.set_margin_start(12)
        content_area.set_margin_end(12)
        content_area.set_spacing(8)

        content_area.append(Gtk.Label(label="Nach wie vielen Minuten soll der Ordner automatisch gesperrt werden?", xalign=0))

        entry_minutes = Gtk.Entry()
        entry_minutes.set_text("10")  # Standardwert
        content_area.append(entry_minutes)

        dialog.connect("response", lambda d, r: self.on_autoclose_dialog_response(d, r, fpath, method, key_file, entry_minutes))
        dialog.present()

    def on_autoclose_dialog_response(self, dialog, response, fpath, method, key_file, entry_minutes):
        autoclose_min = 10
        if response == Gtk.ResponseType.OK:
            try:
                autoclose_min = int(entry_minutes.get_text().strip())
            except ValueError:
                autoclose_min = 10

        dialog.destroy()

        if self.proxy:
            try:
                code = self.proxy.UnlockFolder(fpath, method, key_file, autoclose_min)
                if code != 0:
                    print("Entsperren über D-Bus fehlgeschlagen.")
            except Exception as e:
                print(f"D-Bus Fehler: {e}")

        self.refresh_status()
