#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import subprocess
import json
import time
from pydbus import SystemBus
from gi.repository import GLib

CONFIG_DIR = "/etc/fscrypt-opener"
CONFIG_FILE = os.path.join(CONFIG_DIR, "config")
RUN_DIR = "/run/fscrypt-opener"

class FscryptOpenerService:
    """
    <node>
        <interface name="org.fscrypt.Opener">
            <method name="GetStatus">
                <arg type="s" name="status_json" direction="out"/>
            </method>
            <method name="OpenAll">
                <arg type="i" name="exit_code" direction="out"/>
            </method>
            <method name="CloseAll">
                <arg type="i" name="exit_code" direction="out"/>
            </method>
            <method name="UnlockFolder">
                <arg type="s" name="target_dir" direction="in"/>
                <arg type="s" name="method" direction="in"/>
                <arg type="s" name="key_file" direction="in"/>
                <arg type="i" name="autoclose_min" direction="in"/>
                <arg type="i" name="exit_code" direction="out"/>
            </method>
            <method name="LockFolder">
                <arg type="s" name="target_dir" direction="in"/>
                <arg type="i" name="exit_code" direction="out"/>
            </method>
            <method name="MountImage">
                <arg type="s" name="img_path" direction="in"/>
                <arg type="s" name="mapper_name" direction="in"/>
                <arg type="s" name="mount_point" direction="in"/>
                <arg type="i" name="exit_code" direction="out"/>
            </method>
        </interface>
    </node>
    """

    def __init__(self):
        os.makedirs(CONFIG_DIR, exist_ok=True)
        os.makedirs(RUN_DIR, exist_ok=True)
        if not os.path.exists(CONFIG_FILE):
            with open(CONFIG_FILE, "w") as f:
                f.write("secure_img1|/var/lib/secure1.img|/mnt/secure1|custom\n")

    def GetStatus(self):
        containers = []
        if os.path.exists(CONFIG_FILE):
            with open(CONFIG_FILE, "r") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    parts = [p.strip() for p in line.split("|")]
                    if len(parts) < 4:
                        continue
                    mapper, img, mount, method = parts

                    luks_locked = True
                    actual_mount = "N/A"
                    res = subprocess.run(["cryptsetup", "status", mapper], capture_output=True)
                    if res.returncode == 0:
                        luks_locked = False
                        mres = subprocess.run(["findmnt", "-n", "-o", "TARGET", f"/dev/mapper/{mapper}"], capture_output=True, text=True)
                        actual_mount = mres.stdout.strip() or mount

                    folders = []
                    if not luks_locked and os.path.isdir(actual_mount):
                        for entry in os.listdir(actual_mount):
                            if entry.startswith(".") or entry == "lost+found":
                                continue
                            fpath = os.path.join(actual_mount, entry)
                            if os.path.isdir(fpath):
                                flocked = True
                                sres = subprocess.run(["fscrypt", "status", fpath], capture_output=True, text=True)
                                if "unlocked: yes" in sres.stdout.lower():
                                    flocked = False
                                folders.append({
                                    "name": entry,
                                    "path": fpath,
                                    "locked": flocked,
                                    "method": method
                                })

                    containers.append({
                        "mapper": mapper,
                        "image": img,
                        "mount_point": actual_mount,
                        "luks_locked": luks_locked,
                        "fscrypt_folders": folders
                    })
        return json.dumps({"containers": containers})

    def OpenAll(self):
        if not os.path.exists(CONFIG_FILE):
            return 1
        with open(CONFIG_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = [p.strip() for p in line.split("|")]
                if len(parts) < 4:
                    continue
                mapper, img, mount, _ = parts
                self.MountImage(img, mapper, mount)
        return 0

    def CloseAll(self):
        if os.path.exists(CONFIG_FILE):
            with open(CONFIG_FILE, "r") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    parts = [p.strip() for p in line.split("|")]
                    if len(parts) < 4:
                        continue
                    mapper, _, mount, _ = parts
                    subprocess.run(["umount", mount], capture_output=True)
                    subprocess.run(["cryptsetup", "luksClose", mapper], capture_output=True)
        return 0

    def MountImage(self, img_path, mapper_name, mount_point):
        if not os.path.exists(img_path):
            return 1
        res = subprocess.run(["cryptsetup", "status", mapper_name], capture_output=True)
        if res.returncode != 0:
            open_res = subprocess.run(["cryptsetup", "luksOpen", img_path, mapper_name], capture_output=True)
            if open_res.returncode != 0:
                return 1
        
        os.makedirs(mount_point, exist_ok=True)
        mount_res = subprocess.run(["mount", f"/dev/mapper/{mapper_name}", mount_point], capture_output=True)
        return mount_res.returncode

    def UnlockFolder(self, target_dir, method, key_file, autoclose_min):
        cmd = ["fscrypt", "unlock", "--quiet"]
        if method == "raw_key" and key_file and os.path.exists(key_file):
            cmd.append(f"--key={key_file}")
        cmd.append(target_dir)

        res = subprocess.run(cmd, capture_output=True)
        if res.returncode != 0:
            return 1

        if autoclose_min > 0:
            safe_name = target_dir.replace("/", "_")
            timer_file = os.path.join(RUN_DIR, f"timer_{safe_name}")
            expire_epoch = int(time.time()) + (autoclose_min * 60)
            with open(timer_file, "w") as tf:
                tf.write(str(expire_epoch))

            subprocess.Popen(f"sleep {autoclose_min * 60} && fscrypt lock '{target_dir}' && rm -f '{timer_file}'", shell=True)

        return 0

    def LockFolder(self, target_dir):
        res = subprocess.run(["fscrypt", "lock", target_dir], capture_output=True)
        safe_name = target_dir.replace("/", "_")
        timer_file = os.path.join(RUN_DIR, f"timer_{safe_name}")
        if os.path.exists(timer_file):
            os.remove(timer_file)
        return res.returncode

if __name__ == "__main__":
    bus = SystemBus()
    bus.publish("org.fscrypt.Opener", FscryptOpenerService())
    loop = GLib.MainLoop()
    loop.run()
