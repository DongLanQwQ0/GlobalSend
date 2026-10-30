# Android 安装图标

Android 的安装器与桌面图标使用 `mipmap-anydpi/ic_launcher.xml` 矢量资源，普通、圆形入口指向同一图标。圆环与箭头完整保留边缘留白，背景透明；安装器放大时不再依赖48像素的PNG。Android圆环改用不透明的浅色描边，保持白底下原来的颜色，避免图标归一化只把实色箭头当作轮廓而放大后裁掉淡色圆环；这一厂商行为仍以实际安装页复核。

修改生成器后只更新Android资源：

```powershell
python client/tool/generate_icon.py --android-only
```

该选项不更改Windows或iOS图标。旧密度PNG只作为兼容资源保留；Android资源选择检查确认当前安装器选中矢量图标。

不使用透明背景的`adaptive-icon`：Android的[绘制实现](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-15.0.0_r1/graphics/java/android/graphics/drawable/AdaptiveIconDrawable.java)先用黑色填充内部画布，再叠加背景和前景；透明背景会留下黑底。原生渲染也复现了这一点，因此这里直接使用透明矢量，不以另一块底色代替透明。

`LauncherIconTest` 渲染安装器实际选择的资源，检查完整轮廓、圆形裁剪留白和透明背景。vivo安装界面的实际图标仍需在新APK上查看；框架渲染不代替厂商界面验收。
