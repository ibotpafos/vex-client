// Go's iOS arm64 cgo runtime references these hooks when building without the
// `lldb` tag. Some local toolchains omit the no-lldb object from the c-archive,
// so keep weak no-op definitions in the tunnel target to make simulator builds
// deterministic.
__attribute__((weak)) void darwin_arm_init_thread_exception_port(void) {}
__attribute__((weak)) void darwin_arm_init_mach_exception_handler(void) {}
