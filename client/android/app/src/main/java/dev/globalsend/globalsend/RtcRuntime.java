package dev.globalsend.globalsend;

/** Process lifetime differs from an Activity/Flutter engine's factory lifetime. */
final class RtcRuntime {
    interface Initializer { void initialize(); }
    private boolean initialized;
    synchronized void ensure(Initializer initializer) {
        if (initialized) return;
        initializer.initialize();
        initialized = true;
    }
    synchronized boolean initialized() { return initialized; }
}
