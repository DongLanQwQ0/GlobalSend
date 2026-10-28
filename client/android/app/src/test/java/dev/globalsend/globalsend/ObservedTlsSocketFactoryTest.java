package dev.globalsend.globalsend;

import static org.junit.Assert.*;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import javax.net.ssl.SSLSocketFactory;
import org.junit.Test;

public class ObservedTlsSocketFactoryTest {
    private static final class Delegate extends SSLSocketFactory {
        final Socket value;
        final List<String> calls = new ArrayList<>();
        Delegate(Socket value) { this.value = value; }
        Socket called(String name) { calls.add(name); return value; }
        @Override public String[] getDefaultCipherSuites() { return new String[]{"default"}; }
        @Override public String[] getSupportedCipherSuites() { return new String[]{"supported"}; }
        @Override public Socket createSocket() { return called("empty"); }
        @Override public Socket createSocket(Socket socket,String host,int port,boolean close) { return called("layered"); }
        @Override public Socket createSocket(String host,int port) { return called("host"); }
        @Override public Socket createSocket(String host,int port,InetAddress local,int localPort) { return called("host-local"); }
        @Override public Socket createSocket(InetAddress host,int port) { return called("address"); }
        @Override public Socket createSocket(InetAddress host,int port,InetAddress local,int localPort) { return called("address-local"); }
    }

    @Test public void everyOverloadDelegatesWithoutWrappingOrConnectingTheSocket() throws Exception {
        try (Socket socket = new Socket()) {
            Delegate delegate = new Delegate(socket);
            ObservedTlsSocketFactory observer = new ObservedTlsSocketFactory(delegate);
            InetAddress ip = InetAddress.getLoopbackAddress();
            assertSame(socket, observer.createSocket());
            assertSame(socket, observer.createSocket(socket,"host",1,false));
            assertSame(socket, observer.createSocket("host",1));
            assertSame(socket, observer.createSocket("host",1,ip,0));
            assertSame(socket, observer.createSocket(ip,1));
            assertSame(socket, observer.createSocket(ip,1,ip,0));
            assertEquals(List.of("empty","layered","host","host-local","address","address-local"),delegate.calls);
            assertArrayEquals(new String[]{"default"},observer.getDefaultCipherSuites());
            assertArrayEquals(new String[]{"supported"},observer.getSupportedCipherSuites());
            assertFalse(socket.isConnected());
            assertTrue(observer.endpoints().isEmpty());
        }
    }

    @Test public void endpointsComeFromTheConnectedSocketAndAreNotGuessedBeforeOrAfterIt() throws Exception {
        InetAddress ip = InetAddress.getByName("127.0.0.1");
        try (ServerSocket server = new ServerSocket(0,1,ip); Socket socket = new Socket(ip,server.getLocalPort()); Socket accepted = server.accept()) {
            ObservedTlsSocketFactory observer = new ObservedTlsSocketFactory(new Delegate(socket));
            assertTrue(observer.endpoints().isEmpty());
            observer.createSocket();
            Map<String,Object> endpoints = observer.endpoints();
            assertEquals("127.0.0.1:"+socket.getLocalPort(),endpoints.get("sourceEndpoint"));
            assertEquals("127.0.0.1:"+server.getLocalPort(),endpoints.get("targetEndpoint"));
            socket.close();
            assertTrue(observer.endpoints().isEmpty());
        }
        assertEquals("[0:0:0:0:0:0:0:1]:5000",ObservedTlsSocketFactory.endpoint(InetAddress.getByName("::1"),5000));
    }
}
