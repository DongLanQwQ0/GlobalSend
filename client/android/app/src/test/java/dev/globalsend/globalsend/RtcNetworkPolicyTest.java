package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import java.util.ArrayList;
import java.util.List;
import org.junit.Test;
import org.webrtc.PeerConnectionFactory;

public class RtcNetworkPolicyTest {
    @Test public void probesNeverActivateTheCellularFactoryEvenIfCallerRequestsIt() {
        assertFalse(RtcDataBridge.sessionPolicy("public", true, true).cellular);
        assertFalse(RtcDataBridge.sessionPolicy("lan", true, true).cellular);
        assertTrue(RtcDataBridge.sessionPolicy("public", true, false).cellular);
    }
    @Test public void cellularRequiresBothPublicScopeAndExplicitPermission() {
        assertFalse(new RtcNetworkPolicy("lan", true).cellular);
        assertFalse(new RtcNetworkPolicy("public", false).cellular);
        assertTrue(new RtcNetworkPolicy("public", true).cellular);
        int mask = new RtcNetworkPolicy("lan", true).ignoreMask();
        assertNotEquals(0, mask & PeerConnectionFactory.Options.ADAPTER_TYPE_CELLULAR);
        assertNotEquals(0, mask & PeerConnectionFactory.Options.ADAPTER_TYPE_VPN);
        assertEquals(0x3c0, mask & 0x3c0);
        assertEquals(0, new RtcNetworkPolicy("public", true).ignoreMask());
    }
    @Test public void framesIncludingReadyAreBlockedBeforeNetworkProofAndAfterAForbiddenPairChange() {
        RtcNetworkPolicy.Gate gate = new RtcNetworkPolicy.Gate(new RtcNetworkPolicy("lan", true));
        assertThrows(IllegalStateException.class, gate::requireFrame);
        gate.selected(true, "wifi"); gate.requireFrame();
        gate.selected(true, "ethernet"); gate.requireFrame();
        gate.selected(true, "cellular"); assertThrows(IllegalStateException.class, gate::requireFrame);
        gate.selected(true, "vpn"); assertThrows(IllegalStateException.class, gate::requireFrame);
        gate.selected(true, "unknown"); assertThrows(IllegalStateException.class, gate::requireFrame);
        RtcNetworkPolicy.Gate allowed = new RtcNetworkPolicy.Gate(new RtcNetworkPolicy("public", true));
        assertThrows(IllegalStateException.class, allowed::requireFrame);
        allowed.selected(true, "cellular"); allowed.requireFrame();
    }
    @Test public void revokeClosesOnlyCellularOwnersAndAlsoClosesTheOthersIfOneCloseFails() {
        RtcNetworkPolicy.Owners<RtcNetworkPolicy.Owner> owners = new RtcNetworkPolicy.Owners<>();
        List<String> closed = new ArrayList<>();
        class Owner implements RtcNetworkPolicy.Owner {
            final String id; final boolean cellular, fail;
            Owner(String id, boolean cellular, boolean fail) { this.id = id; this.cellular = cellular; this.fail = fail; }
            @Override public boolean cellular() { return cellular; }
            @Override public void close() { closed.add(id); if (fail) throw new IllegalStateException("fixture close failed"); }
        }
        owners.add("wifi", new Owner("wifi", false, false));
        owners.add("cell-1", new Owner("cell-1", true, true));
        owners.add("cell-2", new Owner("cell-2", true, false));
        assertThrows(IllegalStateException.class, owners::revokeCellular);
        assertEquals(List.of("cell-1", "cell-2"), closed);
        assertNotNull(owners.get("wifi"));
        assertNull(owners.get("cell-1")); assertNull(owners.get("cell-2"));
        owners.closeAll(); assertEquals(List.of("cell-1", "cell-2", "wifi"), closed);
    }
    @Test public void candidateMappingUsesLocalHostOrRelatedAddressNotTheDefaultNetwork() {
        assertEquals("2001:db8::4", RtcDataBridge.localAddress("candidate:1 1 udp 1 2001:db8::4 54321 typ host generation 0"));
        assertEquals("192.168.1.3", RtcDataBridge.localAddress("candidate:1 1 udp 1 203.0.113.8 5000 typ srflx raddr 192.168.1.3 rport 1234"));
        RtcDataBridge.requireDataSdp("v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n");
        assertThrows(IllegalArgumentException.class, () -> RtcDataBridge.requireDataSdp("v=0\r\nm=audio 9 RTP/AVP 0\r\n"));
    }
    @Test public void sameNetworkChangingIpFamilyProducesAnUpdatedRouteReport() {
        RtcNetworkPolicy.Gate gate = new RtcNetworkPolicy.Gate(new RtcNetworkPolicy("public", true));
        assertTrue(gate.reportChanged("wifi", "ipv4"));
        assertFalse(gate.reportChanged("wifi", "ipv4"));
        assertTrue(gate.reportChanged("wifi", "ipv6"));
        assertFalse(gate.reportChanged("wifi", "ipv6"));
    }
    @Test public void twoEnginesShareOneProcessInitializationButCloseTheirOwnOwners() {
        RtcRuntime runtime = new RtcRuntime();
        int[] initializations = {0}, factoriesClosed = {0};
        class Factory implements RtcNetworkPolicy.Owner {
            @Override public boolean cellular() { return false; }
            @Override public void close() { factoriesClosed[0]++; }
        }
        RtcNetworkPolicy.Owners<Factory> engineOne = new RtcNetworkPolicy.Owners<>();
        runtime.ensure(() -> initializations[0]++); engineOne.add("one", new Factory());
        engineOne.closeAll();
        RtcNetworkPolicy.Owners<Factory> engineTwo = new RtcNetworkPolicy.Owners<>();
        runtime.ensure(() -> initializations[0]++); engineTwo.add("two", new Factory());
        assertTrue(runtime.initialized()); assertEquals(1, initializations[0]);
        assertEquals(1, factoriesClosed[0]);
        engineTwo.closeAll(); assertEquals(2, factoriesClosed[0]);
    }
}
