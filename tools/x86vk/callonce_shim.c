/* x86-on-ARM shim for the two pieces of libstdc++ that box64 cannot provide.
 *
 * 1. call_once (C, glibc >= 2.34)
 *    Turnip's dynsym lists it GLOBAL/UND/FUNC and box64's wrapped libc table has
 *    no entry for it, in 0.3.8 or 0.4.3. Implemented with atomics, no libc.
 *
 * 2. std::__once_callable / std::__once_call (C++, libstdc++)
 *    libstdc++'s std::call_once parks a closure pointer in __once_callable and a
 *    trampoline in __once_call, then lets pthread_once invoke the trampoline.
 *    Both are TLS variables reached through R_X86_64_TLSDESC, which box64 reports
 *    as "not supported for now", so they stay NULL and the trampoline call jumps
 *    to a null address. Defining them here gives the loader a resolved symbol
 *    from a preloaded object, which is what keeps the TLSDESC relocation from
 *    being emitted for libvulkan_freedreno's reference.
 *
 * Built with -nostdlib so the result drags in no libraries of its own.
 */
typedef int once_flag_t;

/* ---- 1. C call_once ------------------------------------------------------ */
void call_once(once_flag_t *flag, void (*func)(void))
{
    int state = __atomic_load_n(flag, __ATOMIC_ACQUIRE);
    if (state == 2)
        return;

    int expected = 0;
    if (__atomic_compare_exchange_n(flag, &expected, 1, 0,
                                    __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
        func();
        __atomic_store_n(flag, 2, __ATOMIC_RELEASE);
    } else {
        while (__atomic_load_n(flag, __ATOMIC_ACQUIRE) != 2) {
        }
    }
}

/* ---- 2. libstdc++ once state -------------------------------------------- */
/* One definition each, thread-local, named with the Itanium ABI spellings so no
 * C++ runtime is required: _ZSt15__once_callable / _ZSt11__once_call. */
__thread void *std_once_callable __asm__("_ZSt15__once_callable");
__thread void (*std_once_call)(void) __asm__("_ZSt11__once_call");

/* Non-null placeholder so a trampoline call cannot land on address zero even if
 * libstdc++ never populates the variable. */
static void once_noop(void)
{
}

/* libstdc++ reaches this through pthread_once; keep it valid regardless. */
void __once_proxy(void)
{
    if (std_once_call)
        std_once_call();
    else
        once_noop();
}
