/* d3d9t3.c — DXVK smoke test for wine under box64.
 *
 * Build (mingw-w64, any Linux):
 *   x86_64-w64-mingw32-gcc -O2 d3d9t3.c -o d3d9t3.exe -ld3d9
 * Deploy:
 *   drop DXVK x64 dlls into <prefix>/drive_c/windows/system32/
 *   env -i PATH=/usr/bin:/bin LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu \
 *     WINEPREFIX=<prefix> VK_ICD_FILENAMES=/etc/vulkan/icd.d/panvk_g.json \
 *     box64 <wine64> d3d9t3.exe
 *
 * Full-path LoadLibrary avoids DllOverrides doubts: if system32/d3d9.dll is
 * DXVK and a non-null IDirect3D9 comes back, the whole x86 -> DXVK -> Vulkan
 * -> GPU stack works. Direct3DCreate9 returning NULL after the panvk banner
 * means DXVK rejected the adapter (feature/extension gate), not a load failure.
 */
#include <windows.h>
#include <stdio.h>
#include <d3d9.h>
typedef IDirect3D9 *(WINAPI *PD3C9)(UINT);
int main(void) {
    HMODULE h = LoadLibraryA("C:\\windows\\system32\\d3d9.dll");
    if (!h) { printf("LOADLIB-FAIL err=%lu\n", GetLastError()); return 2; }
    PD3C9 c = (PD3C9)GetProcAddress(h, "Direct3DCreate9");
    if (!c) { printf("GETPROC-FAIL\n"); return 3; }
    IDirect3D9 *d9 = c(D3D_SDK_VERSION);
    if (!d9) { printf("CREATE9-NULL\n"); return 4; }
    UINT ad = IDirect3D9_GetAdapterCount(d9);
    printf("ADAPTERS=%u\n", ad);
    for (UINT i = 0; i < ad; i++) {
        D3DADAPTER_IDENTIFIER9 id;
        if (SUCCEEDED(IDirect3D9_GetAdapterIdentifier(d9, i, 0, &id))) {
            id.Driver[63] = 0; id.Description[127] = 0;
            printf("adapter%u: %s / %s\n", i, id.Driver, id.Description);
        }
    }
    printf("DXVK-GOLD-PASS\n");
    return 0;
}
