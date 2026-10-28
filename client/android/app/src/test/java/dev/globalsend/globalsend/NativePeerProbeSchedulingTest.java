package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.TimeUnit;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

/** Exercises the executor used by the real probePeer MethodChannel branch. */
@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28, manifest = Config.NONE)
public class NativePeerProbeSchedulingTest {
    @Test public void stalledAddressesCannotQueueAReachableCellularCandidatePastTheDecisionDeadline() throws Exception {
        ExecutorService probes = NativeReceiveRuntime.peerProbeExecutor();
        CountDownLatch stalled = new CountDownLatch(2);
        CountDownLatch release = new CountDownLatch(1);
        CountDownLatch reachable = new CountDownLatch(1);
        try {
            for (int i = 0; i < 2; i++) probes.execute(() -> {
                stalled.countDown();
                try { release.await(); }
                catch (InterruptedException stopped) { Thread.currentThread().interrupt(); }
            });
            assertTrue(stalled.await(2, TimeUnit.SECONDS));
            // The third IP has a working route. Its handshake must begin now,
            // even if earlier addresses are still acquiring a Network/TLS.
            probes.execute(reachable::countDown);
            assertTrue("A later reachable address must not wait behind stalled probes",
                reachable.await(1, TimeUnit.SECONDS));
            assertEquals("The stalled probes were not canceled to make room", 1, release.getCount());
        } finally {
            release.countDown(); probes.shutdownNow();
            assertTrue(probes.awaitTermination(2, TimeUnit.SECONDS));
        }
    }
}
