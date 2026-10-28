package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import java.util.List;
import java.util.Map;
import org.junit.Test;
import org.webrtc.RTCStats;

public class RtcStatsTest {
    @Test public void nativeSelectedPairFieldsKeepRealAddressesAndCodecSafePortValues() {
        Map<String, RTCStats> stats = Map.of(
            "transport", new RTCStats(0, "transport", "transport", Map.of("selectedCandidatePairId", "pair", "bytesSent", 99999)),
            "pair", new RTCStats(0, "candidate-pair", "pair", Map.of("localCandidateId", "local", "remoteCandidateId", "remote", "nominated", true, "state", "succeeded")),
            "local", new RTCStats(0, "local-candidate", "local", Map.of("address", "2001:db8::1", "port", 5000)),
            "remote", new RTCStats(0, "remote-candidate", "remote", Map.of("address", "10.0.0.2", "port", 6000L))
        );
        List<Map<String, Object>> rows = RtcDataBridge.statsRows(stats);
        Map<String, Object> transport = rows.stream().filter(row -> "transport".equals(row.get("id"))).findFirst().get();
        assertEquals("pair", transport.get("selectedCandidatePairId"));
        assertFalse(transport.containsKey("bytesSent"));
        Map<String, Object> local = rows.stream().filter(row -> "local".equals(row.get("id"))).findFirst().get();
        assertEquals("2001:db8::1", local.get("address"));
        assertEquals(5000L, local.get("port"));
        Map<String, Object> pair = rows.stream().filter(row -> "pair".equals(row.get("id"))).findFirst().get();
        assertEquals(true, pair.get("nominated"));
        assertEquals("remote", pair.get("remoteCandidateId"));
    }
}
