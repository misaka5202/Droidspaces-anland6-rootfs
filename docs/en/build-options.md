[Documentation index](README.md) · [Project home](../../README_english.md)

# Build Options

Choose the target, desktop, display backend, and optional features on the GitHub Actions `Run workflow` page. Desktop images are intended for ARM64 Droidspaces containers.

## Distribution and desktop support

| Target | Base image | Desktop profiles | Anland Wayland |
| --- | --- | --- | --- |
| `Debian-13` | Debian 13 (trixie) | `none`, `KDE`, `KDE mobile`, `Mobile`, `GNOME`, `Anland Next` | Yes |
| `Ubuntu-24` | Ubuntu 24.04 | `none`, `KDE` | No |
| `Ubuntu-25` | Ubuntu 25.10 | `none`, `KDE` | No |
| `Ubuntu-26` | Ubuntu 26.04 | `none`, `KDE`, `KDE mobile`, `Mobile`, `GNOME`, `Anland Next` | Yes |
| `Fedora-43` | Fedora 43 | `none`, `KDE`, `KDE mobile`, `Mobile`, `GNOME`, `Anland Next` | Yes |
| `Fedora-44` | Fedora 44 | `none`, `KDE`, `KDE mobile`, `Mobile`, `GNOME`, `Anland Next` | Yes |
| `Arch` | Arch Linux ARM | `none`, `KDE`, `KDE mobile`, `Mobile`, `GNOME`, `Anland Next` | Yes (KDE uses Anland Wayland only) |

`all` filters targets according to desktop/backend support. `all-wayland` builds Debian 13, Ubuntu 26, Fedora 43/44, and Arch for KDE/KDE Mobile, GNOME, and Anland Next. Arch KDE, GNOME, KDE Mobile, Mobile, and Anland Next force `anland-wayland`.

| Desktop | Description |
| --- | --- |
| `none` | Command-line environment for SSH, development, or a custom desktop. |
| `KDE` | KDE Plasma; Arch supports Anland Wayland only, while other supported targets may use X11 or Anland Wayland. |
| `KDE mobile` | Touch-first Plasma Mobile; requires Anland Wayland. |
| `Mobile` | A distribution-agnostic touch-friendly app set (contacts, calendar, clocks, weather, maps, browser, terminal); requires Anland Wayland. No mobile shell such as Phosh or Lomiri is installed. |
| `GNOME` | A full Anland Wayland desktop on Debian 13, Ubuntu 26, Fedora 43/44, and Arch Linux ARM, with a terminal, file manager, settings, system monitor, keyring, portal, and common document/media apps. |
| `Anland Next` | An Anland session with rootless Xwayland and mini-wm, without a full desktop; Wayland only. |
| `Niri`, `Hyprland`, `Mango`, `Denial` | **Not in the build matrix.** 6.x launches single apps, so compositor-only profiles are not built. They remain installable manually inside a container via `droidspaces-tui`; they ship a compositor, terminal, XDG portal, audio and fonts, but no application set. |

## Workflow inputs

| Input | Values / default | Description |
| --- | --- | --- |
| `build_target` | Distribution, `all`, `all-wayland`; default `Debian-13` | Select build targets. |
| `custom_username` | 1–32 letters, digits, `_`, or `-`, starting with a letter or `_`; default `Gold` | Normal RootFS user. |
| `desktop` | `none`, `KDE`, `KDE mobile`, `Mobile`, `GNOME`, `Anland Next`; default `KDE` | Selects the primary desktop, i.e. the one that autostarts; `none` is command-line only. |
| `extra_desktops` | Comma-separated desktop names, e.g. `KDE mobile,GNOME`; empty by default | Additional desktop profiles to build alongside the primary one; leave empty to build only the primary desktop. `none` cannot be combined with other desktops, and the option is ignored for the `all-wayland` target. |
| `desktop_autostart` | `true` / `false`; default `true` | Installs the desktop startup service; automatically disabled with a log notice when `desktop` is `none`. |
| `display_backend` | `x11` / `anland-wayland` | Defaults to Wayland in the Chinese workflow and X11 in the English workflow; Arch KDE and some profiles force Wayland. |
| `PulseAudio` | `socket` / `tcp` / `none`; default `socket` | X11 audio forwarding; Anland sets this to `none`. |
| `enable_zh_tz` | `true` / `false` | Installs Chinese locale and Shanghai timezone; defaults differ by workflow. |
| `gpu_vendor` | `qualcomm` / `mediatek` (dual-vendor workflow: `both`); default `qualcomm` | Which GPU stack the image is built for. `qualcomm` installs the Adreno Mesa build and sets kgsl; `mediatek` removes those variables and installs the standard software drivers instead. |
| `enable_mesa` | `true` / `false`; default `true` | Installs Mesa drivers: the Adreno build on Qualcomm, standard software drivers on MediaTek. |
| `enable_8gen2_wayland` | `true` / `false`; default `false` | Sets the Turnip UBWC Wayland workaround for relevant devices. |
| `nosnap` | `true` / `false` | Ubuntu only: removes Snap and prevents APT from reinstalling it; defaults differ by workflow. |
| `enable_systemd257` | `true` / `false`; default `false` | Tries the systemd 257 package family for old Android kernels; only `none` and standard `KDE` are supported. |
| `enable_srf` | `true` / `false` | Installs Fcitx5; enabled by default in the Chinese workflow, disabled in English. |
| `enable_binfmt` | `true` / `false`; default `false` | Adds binfmt cross-architecture support; not recommended for Arch. |
| `enable_yj` | `true` / `false`; default `true` | Improves NAT and Android/Droidspaces hardware recognition. |
| `enable_kfgj` | `true` / `false`; default `false` | Installs development tools such as compilers, CMake, and Python. |
| `enable_zip` | `true` / `false`; default `true` | Installs common compression tools. |
| `enable_docker` | `true` / `false`; default `false` | Installs Docker packages in the RootFS. |
| `wayland_package_repository` | Public `owner/repository`; default `Goldzxcbug/droidspaces-package` | Selects the source for prebuilt Anland package Releases. |

For exact defaults, see `.github/workflows/build-rootfs-releases-en.yml` and `build-rootfs-releases.yml`. `enable_systemd257` is experimental and adds build time. Systems already at systemd 257 or older skip installation; details are in the [script guide](../../scripts/README_english.md).

## Generated Droidspaces recommendations

Native and QEMU builds generate `container.config` from the effective build options.
It is the first regular archive member, followed by the rootfs and then XZ compression.
Old root-level copies are removed; no additional Dockerfile `COPY` is needed.
Droidspaces versions with recommendation support prefill their installation wizard.

| Build option | Recommended setting |
| --- | --- |
| `anland-wayland` | `enable_anland=1`; Termux:X11 and PulseAudio off |
| `x11` | `enable_termux_x11=1`; Anland off |
| X11 with `socket` audio | `enable_pulseaudio=1`; other audio choices use `0` |
| KDE, KDE Mobile, or Mobile | `allow_userns=1` |
| Docker enabled | `net_mode=nat`; otherwise keep the app default |
| Snapdragon GPU support enabled | `enable_gpu_mode=1` |
| Anland Next | `bind_mounts=/data/local/tmp/awl:/run/anland` |
| `enable_zh_tz=true` (Chinese locale and Shanghai timezone) | `dns_servers=114.114.114.114` |

Keys follow the Droidspaces Anland branch. Mount paths live in the config and use
the existing Droidspaces bind-mount parser and runtime. Environment variables are
not passed through this recommendation file. On kernels without user namespaces,
the requested KDE setting stays checked but disabled; this does not add kernel support.

Run the mapping and archive checks with `python3 -m unittest discover -s tests -v`.
