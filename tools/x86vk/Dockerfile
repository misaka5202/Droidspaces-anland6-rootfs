# Probe image, not a desktop image.
#
# It answers one question on real Adreno hardware: can an x86_64 Vulkan client
# drive kgsl when it runs under an x86-on-ARM translator? Everything that
# Steam-on-Adreno needs hangs off that answer, because Proton is x86_64 and the
# only Vulkan ICD it can load must therefore also be x86_64 — while the GPU is
# driven by aarch64 kernel interfaces.
#
# Deliberately carries NO aarch64 graphics stack. Box64 wraps a native library
# in preference to the emulated one whenever it can find it, and the distro's
# aarch64 libxcb/libwayland/X11 are older than what Arch's Turnip 26.x links
# against — a device run failed on exactly that:
#
#   Global Symbol xcb_dri3_import_syncobj_checked not found
#   Global Symbol wl_display_create_queue_with_name not found
#
# Box64 has no per-library "do not wrap" switch in 0.3.8 (BOX64_NOWRAP does not
# exist there; BOX64_PREFER_WRAPPED=0 does not override the built-in list), so
# the reliable way to make it use the emulated libraries is to not ship native
# ones. This image therefore has no mesa-vulkan-drivers, no libxcb, no
# libwayland and no libX11 on the aarch64 side: the only graphics stack present
# is the x86_64 one under /opt/x86root, which is what the probe needs.
#
# Layout of the interesting part:
#   /usr/bin/box64        the translator (native aarch64, from Ubuntu universe)
#   /opt/x86root          a native x86_64 Arch userspace carrying
#                         libvulkan_freedreno.so + freedreno_icd.json
#   /usr/local/bin/xvk-test  runs vulkaninfo through box64 against kgsl
#
# The x86_64 tree is built on the x86_64 CI runner (see the workflow), so no
# emulation is involved in producing it. Only this arm64 image needs qemu.
FROM --platform=linux/arm64 ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

# box64, an init, and the two archivers. Nothing that owns a GPU.
RUN apt-get update && apt-get install -y --no-install-recommends \
        box64 \
        ca-certificates \
        systemd-sysv \
        tar \
        zstd \
    && rm -rf /var/lib/apt/lists/*

# Built by the workflow: Arch bootstrap + vulkan-freedreno (x86_64 Turnip)
# + vulkan-tools (x86_64 vulkaninfo) + every library Turnip links against.
COPY x86root.tar.zst /opt/x86root.tar.zst
RUN tar --zstd -xf /opt/x86root.tar.zst -C /opt \
    && mv /opt/root.x86_64 /opt/x86root \
    && rm -f /opt/x86root.tar.zst

COPY xvk-test /usr/local/bin/xvk-test
RUN chmod 755 /usr/local/bin/xvk-test

CMD ["/sbin/init"]
