package globalsend.acceptance;

import android.graphics.Point;
import android.graphics.Rect;
import com.android.uiautomator.core.UiObject;
import com.android.uiautomator.core.UiSelector;
import com.android.uiautomator.testrunner.UiAutomatorTestCase;

/** Input-only probe. Runs through Android's existing UiAutomator runner. */
public class ZoomGestureTest extends UiAutomatorTestCase {
  private static final String APP = "dev.globalsend.globalsend";
  private static final String[] CONTROLS = {
      "\u6587\u4ef6", "\u5a92\u4f53", "\u53d1\u9001", "\u6253\u5f00", "\u9009\u62e9", "\u786e\u5b9a",
      "\u4e0b\u8f7d", "Downloads", "Open", "\u9002\u5e94\u7a97\u53e3", "\u653e\u5927", "\u7f29\u5c0f",
      "GlobalSend-tests", "\u5185\u90e8\u5b58\u50a8\u7a7a\u95f4", "\u624b\u673a\u5b58\u50a8",
      "\u663e\u793a\u6839\u76ee\u5f55", "\u66f4\u591a\u9009\u9879", "\u56fe\u7247", "Images",
      "GlobalSend-zoom-landscape.png", "GlobalSend-zoom-portrait.png"
  };

  private void requireOwnAppOrPicker() {
    String name = getUiDevice().getCurrentPackageName();
    assertTrue("Refusing input outside GlobalSend/file picker", APP.equals(name)
        || "com.android.documentsui".equals(name) || "com.google.android.documentsui".equals(name)
        || "com.android.filemanager".equals(name));
  }

  private UiObject named(String label, int instance) {
    UiObject item = new UiObject(new UiSelector().text(label).instance(instance));
    if (!item.exists()) item = new UiObject(new UiSelector().description(label).instance(instance));
    if (!item.exists() && label.startsWith("GlobalSend-zoom-"))
      item = new UiObject(new UiSelector().descriptionContains(label).instance(instance));
    return item;
  }

  public void testControls() throws Exception {
    requireOwnAppOrPicker();
    sleep(600);
    System.out.println("GS_ZOOM_PACKAGE " + getUiDevice().getCurrentPackageName());
    for (String label : CONTROLS) {
      for (int index = 0; index < 5; index++) {
        UiObject item = named(label, index);
        if (!item.exists()) break;
        Rect bounds = item.getBounds();
        System.out.println("GS_ZOOM_CONTROL label=" + label + " instance=" + index
            + " bounds=" + bounds.toShortString() + " clickable=" + item.isClickable());
      }
    }
  }

  public void testStructure() throws Exception {
    requireOwnAppOrPicker();
    sleep(600);
    String pkg = getUiDevice().getCurrentPackageName();
    System.out.println("GS_ZOOM_PACKAGE " + pkg);
    for (int index = 0; index < 120; index++) {
      UiObject item = new UiObject(new UiSelector().packageName(pkg).instance(index));
      if (!item.exists()) break;
      String text = item.getText(), description = item.getContentDescription();
      String combined = (text == null ? "" : text) + "\n" + (description == null ? "" : description);
      String recognized = "";
      for (String value : CONTROLS) if (combined.contains(value)) recognized += value + ",";
      System.out.println("GS_ZOOM_NODE index=" + index + " class=" + item.getClassName()
          + " bounds=" + item.getBounds().toShortString() + " clickable=" + item.isClickable()
          + " textLength=" + (text == null ? 0 : text.length())
          + " descLength=" + (description == null ? 0 : description.length()) + " controls=" + recognized);
    }
  }

  public void testClickControl() throws Exception {
    requireOwnAppOrPicker();
    String label = getParams().getString("label");
    boolean allowed = false;
    for (String value : CONTROLS) if (value.equals(label)) allowed = true;
    assertTrue("Unapproved control label", allowed);
    UiObject item = named(label, parameter("instance"));
    assertTrue("Control missing", item.exists());
    assertTrue("Control click rejected", item.click());
    sleep(500);
    System.out.println("GS_ZOOM_CLICK label=" + label);
  }

  public void testViewer() throws Exception {
    requireViewerApp();
    String file = getParams().getString("file");
    assertTrue("Only synthetic images allowed", "GlobalSend-zoom-landscape.png".equals(file)
        || "GlobalSend-zoom-portrait.png".equals(file));
    assertTrue("Synthetic image title missing", named(file, 0).exists());
    assertTrue("Image fit control missing", named("\u9002\u5e94\u7a97\u53e3", 0).exists());
    System.out.println("GS_ZOOM_VIEWER file=" + file);
  }

  private void requireViewerApp() {
    assertEquals("Refusing input outside GlobalSend", APP, getUiDevice().getCurrentPackageName());
  }

  private int parameter(String name) {
    return Integer.parseInt(getParams().getString(name));
  }

  private void requireImagePoint(int x, int y) {
    assertTrue("Point outside central image area", x > 8 && x < getUiDevice().getDisplayWidth() - 8
        && y > getUiDevice().getDisplayHeight() * 0.08
        && y < getUiDevice().getDisplayHeight() * 0.88);
  }

  public void testPinch() throws Exception {
    requireViewerApp();
    int x = parameter("x"), y = parameter("y");
    int initial = parameter("initial"), end = parameter("end");
    requireImagePoint(x - initial, y);
    requireImagePoint(x + initial, y);
    requireImagePoint(x - end, y);
    requireImagePoint(x + end, y);
    UiObject app = new UiObject(new UiSelector().packageName(APP).instance(0));
    assertTrue("GlobalSend root missing", app.exists());
    assertTrue("Two-pointer Android input rejected", app.performTwoPointerGesture(
        new Point(x - initial, y), new Point(x + initial, y),
        new Point(x - end, y), new Point(x + end, y), 72));
    sleep(600);
    requireViewerApp();
    System.out.println("GS_ZOOM_PINCH x=" + x + " y=" + y + " initial=" + initial + " end=" + end);
  }

  public void testPan() throws Exception {
    requireViewerApp();
    int x1 = parameter("x1"), y1 = parameter("y1"), x2 = parameter("x2"), y2 = parameter("y2");
    requireImagePoint(x1, y1);
    requireImagePoint(x2, y2);
    assertTrue("Android pan input rejected", getUiDevice().swipe(x1, y1, x2, y2, 48));
    sleep(450);
    requireViewerApp();
    System.out.println("GS_ZOOM_PAN x1=" + x1 + " y1=" + y1 + " x2=" + x2 + " y2=" + y2);
  }

  public void testFit() throws Exception {
    requireViewerApp();
    String label = "\u9002\u5e94\u7a97\u53e3";
    UiObject fit = new UiObject(new UiSelector().packageName(APP).text(label));
    if (!fit.exists()) fit = new UiObject(new UiSelector().packageName(APP).description(label));
    assertTrue("Fit control not found", fit.exists());
    assertTrue("Fit control rejected click", fit.click());
    sleep(450);
    requireViewerApp();
    System.out.println("GS_ZOOM_FIT");
  }
}
