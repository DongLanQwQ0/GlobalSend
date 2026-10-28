package dev.globalsend.globalsend;

import java.io.IOException;
import java.net.InetAddress;
import java.net.Socket;
import java.util.HashMap;
import java.util.Map;
import javax.net.ssl.SSLSocketFactory;

/** Observes the delegate's real TLS socket; never changes its connect or TLS policy. */
final class ObservedTlsSocketFactory extends SSLSocketFactory {
    private final SSLSocketFactory delegate;
    private volatile Socket last;

    ObservedTlsSocketFactory(SSLSocketFactory delegate) { this.delegate = delegate; }
    private Socket observe(Socket socket) { last = socket; return socket; }
    @Override public String[] getDefaultCipherSuites() { return delegate.getDefaultCipherSuites(); }
    @Override public String[] getSupportedCipherSuites() { return delegate.getSupportedCipherSuites(); }
    @Override public Socket createSocket() throws IOException { return observe(delegate.createSocket()); }
    @Override public Socket createSocket(Socket socket, String host, int port, boolean close) throws IOException { return observe(delegate.createSocket(socket, host, port, close)); }
    @Override public Socket createSocket(String host, int port) throws IOException { return observe(delegate.createSocket(host, port)); }
    @Override public Socket createSocket(String host, int port, InetAddress local, int localPort) throws IOException { return observe(delegate.createSocket(host, port, local, localPort)); }
    @Override public Socket createSocket(InetAddress host, int port) throws IOException { return observe(delegate.createSocket(host, port)); }
    @Override public Socket createSocket(InetAddress host, int port, InetAddress local, int localPort) throws IOException { return observe(delegate.createSocket(host, port, local, localPort)); }

    Map<String, Object> endpoints() {
        Map<String, Object> result = new HashMap<>();
        Socket socket = last;
        if (socket == null || !socket.isConnected() || socket.isClosed()) return result;
        InetAddress local = socket.getLocalAddress(), remote = socket.getInetAddress();
        if (local != null && !local.isAnyLocalAddress() && socket.getLocalPort() > 0)
            result.put("sourceEndpoint", endpoint(local, socket.getLocalPort()));
        if (remote != null && !remote.isAnyLocalAddress() && socket.getPort() > 0)
            result.put("targetEndpoint", endpoint(remote, socket.getPort()));
        return result;
    }

    static String endpoint(InetAddress address, int port) {
        String host = address.getHostAddress();
        return (host.contains(":") ? "[" + host + "]" : host) + ":" + port;
    }
}
