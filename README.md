# hyprland-monitor-wake-fix

Brings back an external monitor that stays black after the screens wake on Hyprland, without replugging the cable and without root.

## The problem

You leave the desk, the screens blank, and when you come back the laptop panel lights up but the external monitor stays black. Hyprland still lists it as on. Blanking and waking again does nothing. Only pulling the cable and plugging it back in gets the picture back.

It needs a blank long enough for the monitor to go into standby. On the monitor this was found with, that is about 26 seconds.

## What is going on

Some monitors answer with a different, smaller EDID while they are in standby. Awake, the monitor here sends three EDID blocks with its full mode list. Asleep, it sends two blocks under a different product name, with nothing above 2560x1440.

1. The screens blank. A little later the monitor goes into standby and signals a hotplug.
2. The kernel reads the standby EDID and replaces its mode list for that connector. Here the new list has nothing above 2560x1080, which is even less than the standby EDID carries, so the kernel is pruning by more than the EDID alone. Hyprland keeps the list from when the monitor was plugged in.
3. On wake, Hyprland asks for the configured mode. That mode is no longer in the kernel's list, so the kernel refuses the modeset with `EINVAL`.
4. Nothing drives the link, so the monitor never wakes and never sends its real EDID. Each side is waiting for the other.

From the kernel's side the connector reads `connected` but `disabled`. From Hyprland's side the monitor is on, at a size the kernel no longer lists for it. That combination is what this tool looks for.

```
$ cat /sys/class/drm/card1-DP-1/{status,enabled}
connected
disabled
$ hyprctl -j monitors all | jq -c '.[] | select(.name == "DP-1") | {width, height, dpmsStatus, disabled}'
{"width":5120,"height":1440,"dpmsStatus":true,"disabled":false}
```

While stuck, Hyprland still offers 5120x1440 for the monitor and the kernel does not:

```
$ hyprctl -j monitors all | jq -r '.[] | select(.name == "DP-1") | .availableModes[]' | grep -c '^5120x1440'
2
$ grep -c '^5120x1440' /sys/class/drm/card1-DP-1/modes
0
```

And in the Hyprland log, on every wake attempt:

```
drm: Modesetting DP-1 with 5120x1440@59.98Hz
atomic drm request: failed to commit: Invalid argument, flags: ATOMIC_ALLOW_MODESET
```

## The fix

Ask for a small mode that the sleeping monitor does offer.

1. Pick the largest of 1920x1080, 1280x720, 1024x768, 800x600 and 640x480 that is in the kernel's current mode list, and set it on the stuck output.
2. The kernel accepts it, the link trains, and the monitor wakes. As it wakes it sends its real EDID.
3. Reload the Hyprland config, which puts your own monitor settings back.

On the test machine the picture is back at the configured mode about six seconds after the wake. Once, the monitor took 20 seconds to come back onto the bus after waking, and the picture returned after about 25.

The two things one would try first do not work, and were tested: a second DPMS off and on repeats the refused modeset, and so does a plain `hyprctl reload`, because Hyprland still holds the old mode list.

## What it leaves alone

- A monitor blanked by DPMS. That is dark on purpose, and it is what every blank looks like.
- A dark monitor whose configured size the kernel still lists. That modeset was refused for another reason, such as a link that will not train or a monitor switched off at its own button, and asking again does not help.
- A monitor turned off in your config.
- Internal panels (`eDP`, `LVDS`, `DSI`).
- A monitor it could not bring back. After three tries it stops and waits until the monitor is blanked, unplugged or lit before it tries again, so it never loops on one that will not wake.
- Your config files. The small mode is set at runtime only, and every attempt ends in a config reload that removes it, whether or not the monitor woke.

## Install

Needs Hyprland, `jq` and a systemd user session.

```
git clone https://github.com/lajwilson/hyprland-monitor-wake-fix
cd hyprland-monitor-wake-fix
./install.sh
```

That copies the script to `~/.local/bin`, the unit to `~/.config/systemd/user`, and starts the service. Nothing is installed system-wide and nothing runs as root, unless you add the optional root helper described below.

The service is tied to `graphical-session.target` and needs `HYPRLAND_INSTANCE_SIGNATURE` and `XDG_RUNTIME_DIR` in the systemd user environment so that `hyprctl` can reach Hyprland. Omarchy and other uwsm sessions provide both. If yours does not, the service will run but never find anything to repair; start the script from your Hyprland autostart instead.

Follow what it does:

```
journalctl --user -u hyprland-monitor-wake-fix -f
```

A repair looks like this:

```
DP-1: stuck after wake, waking its link at 1920x1080@60
DP-1: woke, configured mode restored
```

The second line is only written once the monitor is back on the bus and being driven. A waking monitor usually drops off the bus for a few seconds first. On the test machine it once dropped off and never returned, and only replugging the cable brought it back. No modeset can repair that, so the service waits 45 seconds, says so, and reports what the USB-C ports see:

```
DP-1: dropped off the bus while waking and did not come back in 45s
  port0: partner present
    port0.1: svid ff01 active yes
```

`partner present` means the monitor still holds the cable and only the display signal is gone. `no partner` means the monitor let go of the cable itself.

### Optional root helper

Only root may ask the kernel to look at a connector again, which is the one thing that can find a monitor whose return the kernel missed. If you want the service to try that before you reach for the cable:

```
sudo ./install.sh --root-helper
```

That installs `/usr/local/libexec/hyprland-monitor-wake-fix-detect` and a sudoers rule letting your user run that one file as root without a password. The helper takes a connector name, refuses built-in panels, writes `detect` to the connector's `status`, and prints the status before and after. When the kernel finds the monitor it sends the hotplug event that makes Hyprland light it. It runs only after a monitor has been lost, once per episode:

```
DP-1: asking the kernel to detect it again
  before: disconnected
  after: connected
DP-1: back after the detect
```

Tested by forcing a lit monitor off as root (`echo off` into the connector's `status`): the helper brought it back at the configured mode within a second. It is untested against the real failure, which has happened once. It can only help if the monitor is still asserting itself and the kernel missed it. If the monitor has truly let go, replugging is still the way back. Remove the helper with `sudo ./install.sh --uninstall-root-helper`.

Remove it with `./install.sh --uninstall`.

To check once by hand instead of running the service: `hyprland-monitor-wake-fix --once`.

To see how your own monitor behaves over many wakes, `./soak-test CONNECTOR [CYCLES] [BLANK_SECONDS]` blanks and wakes the screens repeatedly and writes each outcome to `~/.local/state/hyprland-monitor-wake-fix-soak.log`. Both screens are unusable while it runs.

## How it watches

Waking the screens fires no Hyprland event and no DRM hotplug event (both were recorded during a reproduction), so the service polls. Every two seconds it reads two small sysfs files per external connector. It only asks Hyprland anything while a connected monitor is dark.

## Tested on

| | |
|---|---|
| Machine | Dell Inspiron 14 Plus 7440, Intel Meteor Lake Arc graphics, `i915` |
| Monitor | Samsung Odyssey Neo G9 (LS49AG95), 5120x1440@60, DisplayPort over USB-C |
| System | Omarchy 4.5.0, Hyprland 0.56.2 with a Lua config, Linux 7.2.15 |

The fault appeared on every blank that lasted long enough for the monitor to reach standby, and with the service stopped the monitor stayed black. With the service running the monitor came back on all but one wake. An earlier version of the same steps also brought it back on a wake from the lock screen.

A soak of twenty blank and wake cycles, run with `./soak-test card1-DP-1 20`, ended with the monitor lit every time. Seventeen wakes were repaired, sixteen of them in 16 to 18 seconds from the wake and one in 36. The other three needed no repair: on two the monitor never reached standby, and on one it left the bus during the blank and came back by itself.

The one failure came before the soak, after a 31 minute locked blank: the monitor took the small mode, dropped off the bus and never returned until the cable was replugged. An equally long blank 45 minutes earlier woke without any repair, and the soak did not reproduce it, so its cause is not known. The service now reports that case instead of calling it a wake, and the optional root helper retries it.

Not tested:

- The root helper against a monitor that really dropped off the bus. It relit a connector forced off as root, which is the nearest thing that could be staged.
- Other GPU drivers (`amdgpu`, `nvidia`, `xe`) and other monitors. Nothing in the script is specific to a driver, a monitor or USB-C, but it has only run on the hardware above. On NVIDIA in particular, a different recovery that repeated modesets into a powered-off monitor is reported to have frozen a session ([basecamp/omarchy#10925](https://github.com/basecamp/omarchy/pull/10925)). This tool only acts when the kernel's mode list has changed, which is not that case, but it has not been run on NVIDIA.
- Hyprland with a hyprlang (`hyprland.conf`) config. The script uses `hyprctl keyword monitor` there, and that path has not been run.
- A wake from full suspend. The same refused modeset is the likely cause when a monitor stays black after resume and the connector reads `connected` and `disabled`, but only the screen-blank case has been reproduced.

One more thing to know about the test setup: this monitor is pinned to 60 Hz in the Hyprland config because its preferred 120 Hz mode did not train reliably over the cable in use. The fault described here happens at 60 Hz, where the link is otherwise stable, but no other cable has been tried.

## When this will not help

A monitor that drops off the bus while waking and stays away is reported, not repaired, unless the root helper is installed and the monitor is still there for the kernel to find.

If the connector does not read `connected` and `disabled` while the monitor is black, or the kernel still lists the size Hyprland is asking for, this is a different fault and the tool does nothing. In particular it does not help when the kernel still believes it is driving a monitor that is asleep, or when a link will not train at a mode both sides agree on.

## Security

- Runs as your user. No setuid, no network, no files written. No root either, apart from the optional helper, which you install separately.
- Reads `/sys/class/drm` and talks to your own Hyprland over `hyprctl`.
- The only values that go into a Hyprland command are a connector name, which must match `^[A-Za-z0-9-]+$`, and a mode from the fixed list above.

## Licence

MIT. See [LICENSE](LICENSE).
