package dev.globalsend.globalsend;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.Consumer;

/** A real native owner, not a timed delay in cache deletion. */
final class NativeFileLease implements AutoCloseable {
    private final Consumer<Boolean> publish;
    private final AtomicBoolean closed=new AtomicBoolean();
    NativeFileLease(List<String> paths) {publish=DockCoordinator.fileLeasePublisher(paths);publish.accept(true);}
    public void close(){if(closed.compareAndSet(false,true))publish.accept(false);}
}
