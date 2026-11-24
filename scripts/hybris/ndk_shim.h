/* ndk_shim.h — neutralize NDK/clang-only availability macros so gcc can
 * consume the AOSP headers hybris embeds (sync.h and friends). Without it
 * vulkanplatform_*/eglplatform_* silently fail to build; the upstream
 * `make -k install || true` used to swallow exactly that. */
#ifndef NDK_SHIM_H
#define NDK_SHIM_H
#define __INTRODUCED_IN(x)
#define __INTRODUCED_IN_LLNDK(x)
#define __API_AVAILABLE(x)
#define __API_DEPRECATED(...)
#define __AVAILABILITY_INTERNAL_UNAVAILABLE
#define __AVAILABILITY_INTERNAL_WEAK_IMPORT
#define __overloadable
#define __attribute_const__
#endif
