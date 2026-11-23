# Probe image, not a desktop image.
#
# It answers one question on real Adreno hardware: can an x86_64 Vulkan client
# drive kgsl when it runs under an x86-on-ARM translator? Everything that
# Steam-on-Adreno needs hangs off that answer, because Proton is x86_64 and the
# only Vulkan ICD it can load must therefore also be x86_64 — while the GPU is
# driven by aarch64 kernel interfaces.
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

RUN apt-get update && apt-get install -y --no-install-recommends \
        box64 \
        ca-certificates \
        mesa-vulkan-drivers \
        systemd-sysv \
        tar \
        vulkan-tools \
        zstd \
    && rm -rf /var/lib/apt/lists/*

# Built by the workflow: Arch bootstrap + vulkan-freedreno (x86_64 Turnip)
# + vulkan-tools (x86_64 vulkaninfo) + mesa, packed as root.x86_64/.
COPY x86root.tar.zst /opt/x86root.tar.zst
RUN tar --zstd -xf /opt/x86root.tar.zst -C /opt \
    && mv /opt/root.x86_64 /opt/x86root \
    && rm -f /opt/x86root.tar.zst

COPY xvk-test /usr/local/bin/xvk-test
RUN chmod 755 /usr/local/bin/xvk-test

CMD ["/sbin/init"]
