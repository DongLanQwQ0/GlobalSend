package dev.globalsend.globalsend;
import static org.junit.Assert.*;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
@RunWith(RobolectricTestRunner.class) @Config(sdk=34,manifest=Config.NONE)
public class MediaFileNameTest {
    @Test public void numericGalleryNamesKeepMediaSuffixAndExistingNamesStayUnchanged() {
        assertEquals("1000061883.jpg",MediaFileName.withType("1000061883","image/jpeg"));
        assertEquals("1000061889.png",MediaFileName.withType("1000061889","image/png"));
        assertEquals("clip.mp4",MediaFileName.withType("clip","video/mp4"));
        assertEquals("photo.jpeg",MediaFileName.withType("photo.jpeg","image/jpeg"));
        assertEquals("notes",MediaFileName.withType("notes","text/plain"));
        assertEquals("unknown",MediaFileName.withType("unknown",null));
    }
}
