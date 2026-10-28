import 'app_icon.dart';
import 'appearance.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

@immutable
class UiPalette extends ThemeExtension<UiPalette> {
  const UiPalette({
    required this.background,
    required this.surface,
    required this.input,
    required this.ink,
    required this.muted,
    required this.border,
    required this.green,
    required this.softGreen,
    required this.onAccent,
  });
  final Color background,
      surface,
      input,
      ink,
      muted,
      border,
      green,
      softGreen,
      onAccent;
  factory UiPalette.from(Appearance appearance) {
    final dark = appearance.mode == AppearanceMode.dark;
    final accent = (dark
        ? const [
            0xff81d6b4,
            0xff9ecaff,
            0xffc9b6ff,
            0xfff3aec0,
            0xffeac17c,
            0xffb7c9d8,
          ]
        : const [
            0xff176b50,
            0xff245ea8,
            0xff7051a8,
            0xffa34363,
            0xff815c17,
            0xff4c6375,
          ])[appearance.accent.index];
    final neutral = appearance.mode == AppearanceMode.neutral;
    final surface = Color(
      dark
          ? 0xff202124
          : neutral
          ? 0xfff7f7f8
          : 0xffffffff,
    );
    return UiPalette(
      background: Color(
        dark
            ? 0xff141516
            : neutral
            ? 0xffe9eaec
            : 0xfff5f5f6,
      ),
      surface: surface,
      input: neutral
          ? const Color(0xffefeff1)
          : Color.alphaBlend(
              Color(accent).withValues(alpha: dark ? .055 : .03),
              surface,
            ),
      ink: Color(
        dark
            ? 0xffe9eaed
            : neutral
            ? 0xff25272b
            : 0xff25272b,
      ),
      muted: Color(
        dark
            ? 0xffabb0b8
            : neutral
            ? 0xff62666d
            : 0xff62666d,
      ),
      border: Color(
        dark
            ? 0xff3c4046
            : neutral
            ? 0xffd5d7dc
            : 0xffdedfe3,
      ),
      green: Color(accent),
      softGreen: Color.alphaBlend(
        Color(accent).withValues(alpha: dark ? .13 : .08),
        surface,
      ),
      onAccent: dark ? const Color(0xff16191d) : Colors.white,
    );
  }
  @override
  UiPalette copyWith({
    Color? background,
    Color? surface,
    Color? input,
    Color? ink,
    Color? muted,
    Color? border,
    Color? green,
    Color? softGreen,
    Color? onAccent,
  }) => UiPalette(
    background: background ?? this.background,
    surface: surface ?? this.surface,
    input: input ?? this.input,
    ink: ink ?? this.ink,
    muted: muted ?? this.muted,
    border: border ?? this.border,
    green: green ?? this.green,
    softGreen: softGreen ?? this.softGreen,
    onAccent: onAccent ?? this.onAccent,
  );
  @override
  UiPalette lerp(covariant UiPalette? other, double t) {
    if (other == null) return this;
    return UiPalette(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      input: Color.lerp(input, other.input, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      border: Color.lerp(border, other.border, t)!,
      green: Color.lerp(green, other.green, t)!,
      softGreen: Color.lerp(softGreen, other.softGreen, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
    );
  }
}

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

  static UiPalette colors(BuildContext context) =>
      Theme.of(context).extension<UiPalette>() ??
      UiPalette.from(const Appearance());

  static ThemeData theme([Appearance appearance = const Appearance()]) {
    final palette = UiPalette.from(appearance);
    final background = palette.background,
        input = palette.input,
        ink = palette.ink,
        muted = palette.muted,
        border = palette.border,
        green = palette.green;
    final outline = OutlineInputBorder(
      borderRadius: fieldRadius,
      borderSide: BorderSide(color: border),
    );
    const buttonShape = RoundedRectangleBorder(borderRadius: fieldRadius);
    return ThemeData(
      useMaterial3: true,
      brightness: appearance.mode == AppearanceMode.dark
          ? Brightness.dark
          : Brightness.light,
      extensions: [palette],
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
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: green,
            surface: palette.surface,
            brightness: appearance.mode == AppearanceMode.dark
                ? Brightness.dark
                : Brightness.light,
          ).copyWith(
            primary: green,
            onPrimary: palette.onAccent,
            primaryContainer: palette.softGreen,
            onPrimaryContainer: ink,
            surface: palette.surface,
            surfaceContainerLowest: palette.surface,
            surfaceContainerLow: palette.input,
            surfaceContainer: palette.input,
            surfaceContainerHigh: palette.softGreen,
            surfaceContainerHighest: palette.softGreen,
            outline: border,
            onSurface: ink,
            onSurfaceVariant: muted,
            outlineVariant: border,
          ),
      scaffoldBackgroundColor: background,
      iconTheme: IconThemeData(color: muted),
      textTheme: TextTheme(
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
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleSpacing: 24,
        titleTextStyle: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: ink,
          fontFamilyFallback: const [
            'Microsoft YaHei',
            'PingFang SC',
            'sans-serif',
          ],
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: palette.surface,
        indicatorColor: palette.softGreen,
      ),
      inputDecorationTheme: InputDecorationTheme(
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
      cardTheme: CardThemeData(
        elevation: 0,
        color: palette.surface,
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
          side: BorderSide(color: border),
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
      dialogTheme: DialogThemeData(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: radius),
        titleTextStyle: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: ink,
          fontFamilyFallback: const [
            'Microsoft YaHei',
            'PingFang SC',
            'sans-serif',
          ],
        ),
        contentTextStyle: TextStyle(
          fontSize: 16,
          height: 1.55,
          color: ink,
          fontFamilyFallback: const [
            'Microsoft YaHei',
            'PingFang SC',
            'sans-serif',
          ],
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: palette.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: fieldRadius),
        textStyle: TextStyle(
          fontSize: 15,
          color: ink,
          fontFamilyFallback: const [
            'Microsoft YaHei',
            'PingFang SC',
            'sans-serif',
          ],
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: palette.surface,
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
      dividerTheme: DividerThemeData(color: border, thickness: 1, space: 24),
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
        style: TextStyle(
          fontSize: 14,
          height: 1.4,
          fontWeight: FontWeight.w600,
          color: Ui.colors(context).muted,
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
}) => Builder(
  builder: (context) => Material(
    color: Ui.colors(context).input,
    shape: RoundedRectangleBorder(
      borderRadius: Ui.cardRadius,
      side: BorderSide(color: Ui.colors(context).border),
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
  ),
);

class AppearancePicker extends StatelessWidget {
  const AppearancePicker({super.key});
  @override
  Widget build(BuildContext context) {
    final settings = AppearanceScope.maybeOf(context);
    if (settings == null) return const SizedBox.shrink();
    final value = settings.value;
    Future<void> save({AppearanceMode? mode, AccentColor? accent}) async {
      try {
        await settings.set(mode: mode, accent: accent);
      } catch (_) {
        if (context.mounted)
          ScaffoldMessenger.maybeOf(context)
              ?.showSnackBar(const SnackBar(content: Text('外观未保存，请重试')));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<AppearanceMode>(
          key: const ValueKey('appearance-mode'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: AppearanceMode.light, label: Text('亮色')),
            ButtonSegment(value: AppearanceMode.dark, label: Text('暗色')),
            ButtonSegment(value: AppearanceMode.neutral, label: Text('中性')),
          ],
          selected: {value.mode},
          onSelectionChanged: (selected) => save(mode: selected.single),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final accent in AccentColor.values)
              Semantics(
                button: true,
                selected: value.accent == accent,
                label: const ['绿', '蓝', '紫', '玫瑰', '琥珀', '石板'][accent.index],
                child: Tooltip(
                  message: const [
                    '绿',
                    '蓝',
                    '紫',
                    '玫瑰',
                    '琥珀',
                    '石板',
                  ][accent.index],
                  child: InkResponse(
                    key: ValueKey('accent-${accent.name}'),
                    onTap: () => save(accent: accent),
                    radius: 24,
                    child: SizedBox.square(
                      dimension: 44,
                      child: Center(
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: UiPalette.from(
                              value.copyWith(accent: accent),
                            ).green,
                          ),
                          child: value.accent == accent
                              ? AppIcon(
                                  Icons.done,
                                  size: 20,
                                  color: UiPalette.from(value).onAccent,
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

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
          AppIcon(icon, size: 40, color: Ui.colors(context).muted),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: Ui.colors(context).muted),
          ),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    ),
  );
}
