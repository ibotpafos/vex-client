import java.lang.reflect.Method;
import java.lang.reflect.Proxy;

/** Load the actual APK/JNI on a phone without opening a TUN or dialing sockets. */
public final class NativeRoutingProbe {
    public static void main(String[] args) throws Exception {
        if (args.length != 1) throw new IllegalArgumentException("native library path required");
        Class<?> backend = Class.forName("org.amnezia.awg.GoBackend");
        Class<?> protector = Class.forName("org.amnezia.awg.GoBackend$SocketProtector");
        protector.getMethod("prepare", int.class, long.class, int.class);
        Object deny = Proxy.newProxyInstance(protector.getClassLoader(), new Class<?>[]{protector},
            (proxy, method, values) -> false);
        System.load(args[0]);
        Object version = backend.getMethod("awgVersion").invoke(null);
        if (!(version instanceof String) || ((String) version).isEmpty()) throw new IllegalStateException("AWG version unavailable");
        Method routed = backend.getMethod("awgTurnOnRouted", String.class, int.class, String.class, String.class,
            protector, long.class, boolean.class);
        // Invalid policy and FD are deliberate. Admission must refuse before
        // creating capture or transport; the JNI callback descriptor is real.
        int result = (Integer) routed.invoke(null, "vex-qa", -1, "", "{}", deny, 1L, true);
        if (result != -1) throw new IllegalStateException("invalid routing parameters were admitted");
        boolean active = (Boolean) backend.getMethod("awgRouterCaptureActive", int.class).invoke(null, -1);
        if (active) throw new IllegalStateException("invalid handle owns capture");
        System.out.println("NATIVE_ROUTING_JNI_LOAD=PASS");
        System.out.println("PROTECTOR_DESCRIPTOR=PASS");
        System.out.println("INVALID_ADMISSION=PASS");
        System.out.println("PACKET_ROUTING_ACCEPTANCE=NOT_RUN");
    }
}
