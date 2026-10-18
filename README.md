# Sony A7C II FL2/FL3 — Linux One-Click Script

English | [简体中文](./README_ZH.md)

Install the FL2 and FL3 still-photo Creative Looks on a **Sony A7C II (ILCE-7CM2) running firmware 2.01** entirely from **Linux** — no Windows required.

This repository contains only a Bash script and documentation. The port, firmware patches and installer all come from [QAQLeonard/a7c2-fl23-research](https://github.com/QAQLeonard/a7c2-fl23-research). The script runs that Windows toolkit on Linux and handles the Linux-specific USB issues. **It does not modify any upstream code.**

> [!WARNING]
> **This is an experimental, unofficial firmware modification. It can leave your camera unable to boot.**
> The upstream preview has been validated on very few bodies; this Linux workflow has been completed end to end on one A7C II (Arch Linux).
> Backups and readbacks detect errors; they do not guarantee recovery. Use at your own risk. Not affiliated with Sony.

## Tested

| Item | Result |
|---|---|
| System | Arch Linux (Omarchy), kernel 7.x, Python 3.12 (uv-managed venv) |
| Camera | One ILCE-7CM2, firmware 2.01 |
| prepare / install | Programs written and fully read back with the expected hashes; settings written, saved and read back |
| After cold start | FL2 and FL3 appear in the menu, can be selected and used to shoot |
| Not tested | Other distributions, a second body, running `verify` / `restore` on Linux |

## Quick start

```bash
git clone https://github.com/nimrc/sony-a7c2-fl23-linux.git
cd sony-a7c2-fl23-linux
./a7c2-fl23.sh            # guided: setup -> prepare -> install
```

Or step by step:

```bash
./a7c2-fl23.sh setup      # download and verify the toolkit, create the Python env, install the udev rule (no camera)
./a7c2-fl23.sh prepare    # back up and check (no program writes)
./a7c2-fl23.sh install    # install (writes to the camera)
./a7c2-fl23.sh verify     # check after the cold start (optional)
./a7c2-fl23.sh restore    # restore the official programs from this body's backup
./a7c2-fl23.sh status     # show workspace state and the camera's USB identity
```

The script's messages are in Chinese. Data lives in `~/a7c2-fl23/` by default:

| Directory | Contents |
|---|---|
| `toolkit/` | Upstream toolkit and its Python environment |
| `work/` | Workspace: this body's original programs, settings backup and operation journal. **Restoring depends on it** |
| `backup/` | Second backup copy. Put it on another disk with `A7C2_BACKUP=/other/disk/path` |
| `logs/` | Full output of every run and evidence from failures |

## Requirements

- **Camera**: A7C II on firmware 2.01. The toolkit checks the hashes of the camera's program files and refuses anything else. Battery at least 50%.
- **USB**: a data-capable cable connected directly, no hub. Set the camera's USB connection mode to **Mass Storage**.
- **System**: `bash`, `curl`, `unzip`, `udisks2` (`udisksctl`), `sudo`, and Python 3.10–3.13 or [uv](https://docs.astral.sh/uv/) (recommended). The GUI also needs Tkinter (Arch: `sudo pacman -S tk`).
- **Not needed**: Zadig or any Windows driver.

## Workflow

1. **setup**: downloads `a7c2-fl23-2.01-preview-0.1.0.zip` from a pinned upstream commit, checks its SHA-256 (`2bbbf394…6c75`), creates the Python environment, runs the upstream offline tests and installs the udev rule `/etc/udev/rules.d/70-sony-a7c2.rules`.
2. **prepare**: connect the camera. The script hands over the USB device and runs upstream `prepare`, which reads and backs up the camera's original programs and settings (two copies), builds the patched candidates on the computer and runs read-only checks on the camera. **The camera is not modified.**
3. **Reconnect**: unplug, power the camera off and on normally, set Mass Storage and plug it back into **the same USB port**.
4. **install**: enter the actual battery level, then type `INSTALL` to confirm. The script runs upstream `install`, which takes about a minute. Don't touch the camera or cable; the script blocks system sleep.
5. **Cold start**: unplug → shut down normally and wait for the access lamp to go off → **remove the battery for about 10 seconds** → reinsert and power on. Toggling the power switch alone does not load the new looks.
6. **Check**: FL2 and FL3 should appear in the menu. Select each one, use the camera's built-in reset, and confirm the eight values (Contrast, Highlights, Shadows, Fade, Saturation, Sharpness, Sharpness Range, Clarity) are `0, 0, 0, 1, 0, 4, 3, 1`. Then shoot and play back a few frames with ST, FL2 and FL3.

## Linux pitfalls (handled by the script)

The upstream toolkit was only tested on Windows. Running it directly on Linux hits these problems:

| Symptom | Cause | What the script does |
|---|---|---|
| `[Errno 16] Resource busy` | The kernel `usb-storage` driver holds the camera interface. PMCA detaches kernel drivers in `UsbBackend.reset()`, but upstream `transport.py` overrides `reset()` in its `Bounded` class, so the detach never happens. Windows is unaffected because Zadig replaces the driver | Unbinds the camera interface from `usb-storage` before every run |
| `[Errno 110] Operation timed out` while reading the camera model | With the `usb_storage` quirk `054c:0e8a:i` (kernel ignores the camera), standard storage commands work but Sony extended commands time out. The camera appears to need one normal mass-storage initialisation by the kernel first | **Does not** use quirks: lets the kernel initialise and mount the camera, unmounts, then unbinds. Removes a leftover quirk automatically |
| udev rule has no effect; device is root-only | A rule file numbered `99-` sorts after `73-seat-late.rules`, so `uaccess` is never applied | Names the rule `70-…` |
| `服務身份未出現` (service identity did not appear); camera becomes `054c:0d68` instead of `0336` after authentication | Depends on the USB port: another port on the same computer worked | Suggests switching ports on failure |

## When something fails

**Do not simply rerun a write.** The script never retries on its own.

- **install / verify failed and the operation journal has no new entries**: the session never got as far as writing (upstream `install` always journals before its first write), so the camera was not modified. The script backs up the state file and resets the workspace phase. Follow the prompt: unplug, power-cycle the camera, switch USB ports if needed, and rerun the same command.
- **Anything else**: the script warns that writing may have started. Don't rerun, don't pull the battery, keep `~/a7c2-fl23/work` and `logs/`, and establish the state first. You can open an issue upstream with the logs, but **never attach `*.private.bin`** — those contain the camera's private settings.
- **prepare failed**: the script moves the old workspace and backup to `logs/failed-<timestamp>/` and starts over with empty directories.

## Restoring the official firmware programs

Select ST on the camera, do a full cold start (shut down, remove the battery for 10 seconds, power on), then connect:

```bash
./a7c2-fl23.sh restore
```

Restore only works with the `work/` directory of **the same body**. Do another cold start afterwards.

## Privacy

`work/`, `backup/` and `logs/` contain the camera's settings backup (`*.private.bin`), and logs may include a hash of the serial number. **Do not upload or publish these files.**

## Credits and sources

- [QAQLeonard/a7c2-fl23-research](https://github.com/QAQLeonard/a7c2-fl23-research): the A7C II 2.01 FL2/FL3 port, preview toolkit and all research documentation. This repository pins commit `dd01c07`.
- [lzh2016zzz/a7cr-fl23-research](https://github.com/lzh2016zzz/a7cr-fl23-research), [YuuLuo/a7c2-service-preload](https://github.com/YuuLuo/a7c2-service-preload), [ma1co/Sony-PMCA-RE](https://github.com/ma1co/Sony-PMCA-RE): research the upstream work builds on.
- Sony trademarks and firmware-data rights belong to their respective holders. This repository contains no Sony firmware and does not redistribute the upstream toolkit.

## License

- `a7c2-fl23.sh`: MIT, see [LICENSE](./LICENSE).
- READMEs: [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/); parts are adapted from the upstream documentation.
- The upstream toolkit is covered by its own `LICENSE`, `NOTICE.md` and `licenses/`.
