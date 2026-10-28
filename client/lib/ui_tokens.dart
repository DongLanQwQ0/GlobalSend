import 'app_icon.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

/// Shared visual language; transfer, focus and persistence stay with callers.
abstract final class Ui {
  static const background = Color(0xfff4f6f2);
  static const input = Color(0xfffafcf9);
  static const ink = Color(0xff202923);
  static const muted = Color(0xff667068);
  static const border = Color(0xffdfe6df);
  static const green = Color(0xff176b50);
  static const softGreen = Color(0xffedf4ef);
  static const radius = BorderRadius.all(Radius.circular(20));
  static const fieldRadius = BorderRadius.all(Radius.circular(14));
  static const cardRadius = BorderRadius.all(Radius.circular(16));

  static ThemeData theme() {
    const outline = OutlineInputBorder(
      borderRadius: fieldRadius,
      borderSide: BorderSide(color: border),
    );
    const buttonShape = RoundedRectangleBorder(borderRadius: fieldRadius);
    return ThemeData(
      useMaterial3: true,
      fontFamily: switch (defaultTargetPlatform) {
        TargetPlatform.windows => 'Segoe UI',
        TargetPlatform.iOS || TargetPlatform.macOS => '.AppleSystemUIFont',
        _ => null,
      },
      fontFamilyFallback: const [
        'Microsoft YaHei',
        'PingFang SC',
        'sans-serif',
      ],
      actionIconTheme: ActionIconThemeData(
        backButtonIconBuilder: (context) => AppIcon(
          Theme.of(context).platform == TargetPlatform.iOS ||
                  Theme.of(context).platform == TargetPlatform.macOS
              ? Icons.arrow_back_ios_new_rounded
              : Icons.arrow_back,
        ),
        closeButtonIconBuilder: (_) => const AppIcon(Icons.close),
        drawerButtonIconBuilder: (_) => const AppIcon(Icons.menu),
        endDrawerButtonIconBuilder: (_) => const AppIcon(Icons.menu),
      ),
      colorScheme: ColorScheme.fromSeed(seedColor: green, surface: Colors.white)
          .copyWith(
            primary: green,
            onSurface: ink,
            onSurfaceVariant: muted,
            outlineVariant: border,
          ),
      scaffoldBackgroundColor: background,
      textTheme: const TextTheme(
        bodyMedium: TextStyle(fontSize: 16, height: 1.55),
        bodyLarge: TextStyle(fontSize: 16, height: 1.55),
        bodySmall: TextStyle(fontSize: 13, height: 1.45, color: muted),
        titleLarge: TextStyle(
          fontSize: 24,
          height: 1.3,
          fontWeight: FontWeight.w600,
        ),
        titleMedium: TextStyle(
          fontSize: 16,
          height: 1.4,
          fontWeight: FontWeight.w600,
        ),
        labelLarge: TextStyle(
          fontSize: 14,
          height: 1.35,
          fontWeight: FontWeight.w600,
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleSpacing: 24,
        titleTextStyle: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: ink,
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: Color(0xffe0eee7),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: outline,
        enabledBorder: outline,
        focusedBorder: OutlineInputBorder(
          borderRadius: fieldRadius,
          borderSide: BorderSide(color: green, width: 1.5),
        ),
        filled: true,
        fillColor: input,
        constraints: BoxConstraints(minHeight: 56),
        contentPadding: EdgeInsets.all(16),
        hintStyle: TextStyle(fontSize: 15, color: muted),
      ),
      cardTheme: const CardThemeData(
        elevation: 0,
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: border),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(88, 48),
          shape: buttonShape,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(88, 48),
          shape: buttonShape,
          side: const BorderSide(color: border),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: buttonShape,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(40, 40),
          padding: const EdgeInsets.all(8),
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: radius),
        titleTextStyle: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: ink,
        ),
        contentTextStyle: TextStyle(fontSize: 16, height: 1.55, color: ink),
      ),
      popupMenuTheme: const PopupMenuThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: fieldRadius),
        textStyle: TextStyle(fontSize: 15, color: ink),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        minVerticalPadding: 12,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: fieldRadius),
      ),
      dividerTheme: const DividerThemeData(
        color: border,
        thickness: 1,
        space: 24,
      ),
    );
  }

  static Size editorSize(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final width = math.min(680.0, viewport.width - 32);
    final available =
        viewport.height - MediaQuery.viewInsetsOf(context).bottom - 48;
    return Size(
      width,
      math.min((width - 40) * .75 + 128, math.max(160, available)),
    );
  }
}

/// The accepted receipt toolbar spacing, shared by local content pages.
/// Keep the existing 44px batch-drag hit area even when it is temporarily absent.
class UiContentToolbar extends StatelessWidget {
  const UiContentToolbar({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
    child: SizedBox(
      height: 44,
      child: TextButtonTheme(
        data: TextButtonThemeData(
          style: TextButton.styleFrom(
            minimumSize: const Size(40, 36),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            visualDensity: VisualDensity.standard,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        child: LayoutBuilder(
          builder: (context, bounds) => ScrollConfiguration(
            behavior: ScrollConfiguration.of(context)
                .copyWith(scrollbars: false),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: bounds.maxWidth),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: children,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class UiField extends StatelessWidget {
  const UiField({super.key, required this.label, required this.child});
  final String label;
  final Widget child;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        label,
        style: const TextStyle(
          fontSize: 14,
          height: 1.4,
          fontWeight: FontWeight.w600,
          color: Ui.muted,
        ),
      ),
      const SizedBox(height: 8),
      Semantics(label: label, child: child),
    ],
  );
}

class UiSection extends StatelessWidget {
  const UiSection({
    super.key,
    required this.title,
    required this.children,
    this.padding = 24,
  });
  final String title;
  final List<Widget> children;
  final double padding;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: EdgeInsets.all(padding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 24),
          ...children,
        ],
      ),
    ),
  );
}

Widget uiDisclosure({
  Key? key,
  required String title,
  required List<Widget> children,
}) => Material(
  color: Ui.input,
  shape: const RoundedRectangleBorder(
    borderRadius: Ui.cardRadius,
    side: BorderSide(color: Ui.border),
  ),
  clipBehavior: Clip.antiAlias,
  child: AppExpansionTile(
    key: key,
    title: Text(
      title,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    ),
    tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    shape: const Border(),
    collapsedShape: const Border(),
    children: children,
  ),
);

class UiEmpty extends StatelessWidget {
  const UiEmpty({
    super.key,
    required this.icon,
    required this.title,
    this.action,
  });
  final IconData icon;
  final String title;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(icon, size: 40, color: Ui.muted),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, color: Ui.muted),
          ),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    ),
  );
}
