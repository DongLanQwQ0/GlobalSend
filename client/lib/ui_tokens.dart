import 'app_icon.dart';
import 'appearance.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

/// Signal colours live outside the accent axis, one pair per brightness.
/// The dark pair is deliberately desaturated so nothing glows on a dark canvas.
// Same ARGB as the web palette in web/src/appearance.ts so both platforms warn
// and fail in exactly the same hue. Contrast stays above 4.5:1 in both modes.
const Color _dangerLight = Color(0xffa94237);
const Color _warningLight = Color(0xff85662b);
const Color _dangerDark = Color(0xffffb4a7);
const Color _warningDark = Color(0xffeac17c);

/// One appearance's colour set.
///
/// The nine legacy fields keep their names, units and roles because widgets
/// already read them; the semantic getters below are the vocabulary new code
/// should use, and the state getters are the only place hover / pressed /
/// selected / disabled are decided.
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
    this.danger = _dangerLight,
    this.warning = _warningLight,
    this.brightness = Brightness.light,
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
  final Color danger, warning;
  final Brightness brightness;

  /// Shorthand for the two derived ladders that need to know the brightness.
  bool get isDark => brightness == Brightness.dark;

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
      danger: dark ? _dangerDark : _dangerLight,
      warning: dark ? _warningDark : _warningLight,
      brightness: dark ? Brightness.dark : Brightness.light,
    );
  }

  // ── Semantic aliases ───────────────────────────────────────────────────
  // Same colours, role names: surface carries content, surfaceMuted is the
  // weak/inert surface, line is the single 1px separator, textPrimary /
  // textSecondary are the two readable inks.

  Color get canvas => background;
  Color get surfaceMuted => input;
  Color get line => border;
  Color get textPrimary => ink;
  Color get textSecondary => muted;
  Color get accent => green;
  Color get accentOn => onAccent;
  Color get accentSoft => softGreen;
  Color get dangerSoft =>
      Color.alphaBlend(danger.withValues(alpha: isDark ? .18 : .08), surface);
  Color get warningSoft =>
      Color.alphaBlend(warning.withValues(alpha: isDark ? .18 : .09), surface);

  // ── Interaction states ─────────────────────────────────────────────────
  // All four are ink veils over one surface, so hover, pressed and disabled
  // read as one scale in both themes instead of being recomputed in widgets.

  /// Ink veil over [surface]; the only primitive the state colours use.
  Color _veil(double strength) =>
      Color.alphaBlend(ink.withValues(alpha: strength), surface);

  Color get hovered => _veil(isDark ? .06 : .04);
  Color get pressed => _veil(isDark ? .12 : .08);
  Color get selected => softGreen;
  Color get selectedLine =>
      Color.alphaBlend(green.withValues(alpha: .55), border);

  /// Visible focus halo; [Ui.ringWidth] wide.
  Color get focusRing =>
      Color.alphaBlend(green.withValues(alpha: isDark ? .45 : .35), surface);

  /// Disabled is one rule for every surface: 45% of the normal foreground.
  Color disabledOf(Color foreground) =>
      foreground.withValues(alpha: Ui.disabledOpacity);
  Color get disabledInk => disabledOf(textSecondary);
  Color get disabledFill => _veil(isDark ? .14 : .10);
  Color get disabledLine => disabledOf(border);

  // ── Elevation ──────────────────────────────────────────────────────────
  // Shadows come from one tint per appearance: light keeps a trace of the
  // accent hue, dark strips it to neutral so depth never reads as haze.

  Color get shadowTint => isDark
      ? const Color(0xff000000)
      : Color.alphaBlend(green.withValues(alpha: .12), const Color(0xff0a0f0d));

  Color shadowAt(double strength) => shadowTint.withValues(alpha: strength);

  /// No elevation: the resting state of every surface.
  List<BoxShadow> get shadow0 => const <BoxShadow>[];

  /// Level 1: a card lifting off the canvas (hover / sticky row).
  List<BoxShadow> get shadow1 => <BoxShadow>[
    BoxShadow(
      color: shadowAt(isDark ? .34 : .08),
      blurRadius: 3,
      offset: const Offset(0, 1),
    ),
  ];

  /// Level 2: an overlay that owns the pointer (menus, sheets, popovers).
  List<BoxShadow> get shadow2 => <BoxShadow>[
    BoxShadow(
      color: shadowAt(isDark ? .42 : .12),
      blurRadius: 14,
      offset: const Offset(0, 5),
    ),
  ];

  /// Level 3: a modal that dims everything behind it.
  List<BoxShadow> get shadow3 => <BoxShadow>[
    BoxShadow(
      color: shadowAt(isDark ? .52 : .18),
      blurRadius: 36,
      offset: const Offset(0, 14),
    ),
  ];

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
    Color? danger,
    Color? warning,
    Brightness? brightness,
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
    danger: danger ?? this.danger,
    warning: warning ?? this.warning,
    brightness: brightness ?? this.brightness,
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
      danger: Color.lerp(danger, other.danger, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      brightness: t < .5 ? brightness : other.brightness,
    );
  }
}

/// Shared visual language; transfer, focus and persistence stay with callers.
///
/// Colours are per-appearance and reached through [colors]; everything else in
/// this file is a fixed step on a ladder (spacing, radius, type, elevation,
/// motion), so no widget needs to invent a number or compute a state colour.
abstract final class Ui {
  // ── Palette fallbacks ──────────────────────────────────────────────────
  // Kept for API compatibility; they mirror UiPalette.from(const Appearance()).

  static const background = Color(0xfff5f5f6);
  static const input = Color(0xfff8fbfa);
  static const ink = Color(0xff25272b);
  static const muted = Color(0xff62666d);
  static const border = Color(0xffdedfe3);
  static const green = Color(0xff176b50);
  static const softGreen = Color(0xffecf3f1);

  // ── Spacing ladder (4px rhythm; mirrors the web foundation --space-*) ──

  static const double space0 = 4;
  static const double space1 = 8;
  static const double space2 = 12;
  static const double space3 = 16;
  static const double space4 = 24;
  static const double space5 = 32;
  static const double space6 = 40;
  static const double space7 = 48;
  static const double space8 = 64;

  static const EdgeInsets insetField = EdgeInsets.all(space3);
  static const EdgeInsets insetPanel = EdgeInsets.all(space4);

  // ── Radius ladder ──────────────────────────────────────────────────────

  /// Control: buttons, inputs, menus, snack bars.
  static const double radiusControl = 10;

  /// Card: every content container.
  static const double radiusCard = 14;

  /// Panel: dialogs, sheets and other full-height surfaces.
  static const double radiusPanel = 18;

  /// Pill: fully rounded chips and dots.
  static const double radiusPill = 999;

  static const fieldRadius = BorderRadius.all(Radius.circular(radiusControl));
  static const cardRadius = BorderRadius.all(Radius.circular(radiusCard));
  static const panelRadius = BorderRadius.all(Radius.circular(radiusPanel));
  static const pillRadius = BorderRadius.all(Radius.circular(radiusPill));

  /// Legacy alias: used by the card theme, now on the card step.
  static const radius = cardRadius;

  // ── Type ladder ────────────────────────────────────────────────────────

  static const double text2xs = 12;
  static const double textXs = 13;
  static const double textSm = 14;
  static const double textBase = 16;
  static const double textLg = 18;
  static const double textXl = 22;
  static const double text2xl = 28;

  static const double leadingTight = 1.25;
  static const double leadingCompact = 1.45;
  static const double leadingNormal = 1.55;
  static const double leadingRelaxed = 1.7;

  /// Two steps only: 400 for reading, 600 for labels. Nothing heavier at small
  /// sizes and nothing lighter for Chinese titles.
  static const FontWeight weightBody = FontWeight.w400;
  static const FontWeight weightLabel = FontWeight.w600;

  static const List<String> fontFallback = [
    'Microsoft YaHei',
    'PingFang SC',
    'sans-serif',
  ];

  static const TextStyle body = TextStyle(
    fontSize: textBase,
    height: leadingNormal,
  );
  static const TextStyle caption = TextStyle(
    fontSize: textXs,
    height: leadingCompact,
  );
  static const TextStyle label = TextStyle(
    fontSize: textSm,
    height: leadingTight,
    fontWeight: weightLabel,
  );
  static const TextStyle subtitle = TextStyle(
    fontSize: textBase,
    height: leadingCompact,
    fontWeight: weightLabel,
  );
  static const TextStyle title = TextStyle(
    fontSize: textXl,
    height: leadingTight,
    fontWeight: weightLabel,
  );
  static const TextStyle display = TextStyle(
    fontSize: text2xl,
    height: leadingTight,
    fontWeight: weightLabel,
  );

  // ── Strokes, sizes, motion ─────────────────────────────────────────────

  static const double stroke = 1;
  static const double strokeFocus = 2;
  static const double ringWidth = 3;

  /// Minimum touch target (mobile); desktop controls may sit at [rowHeight].
  static const double touch = 44;
  static const double controlHeight = 48;
  static const double rowHeight = 40;
  static const double fieldHeight = 56;

  static const double iconSm = 18;
  static const double iconMd = 24;
  static const double iconLg = 40;

  static const double disabledOpacity = .45;

  static const Duration durationFast = Duration(milliseconds: 110);
  static const Duration durationNormal = Duration(milliseconds: 170);
  static const Duration durationSlow = Duration(milliseconds: 260);
  static const Curve ease = Cubic(.2, 0, .2, 1);

  // ── Elevation ladder (Material numbers; shadows live on the palette) ───

  static const double elevationFlat = 0;
  static const double elevationRaised = 1;
  static const double elevationOverlay = 3;
  static const double elevationModal = 6;

  static const double editorMaxWidth = 680;

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
      brightness: palette.brightness,
      extensions: [palette],
      fontFamily: switch (defaultTargetPlatform) {
        TargetPlatform.windows => 'Segoe UI',
        TargetPlatform.iOS || TargetPlatform.macOS => '.AppleSystemUIFont',
        _ => null,
      },
      fontFamilyFallback: fontFallback,
      // States come from tokens, never from each widget's own blend.
      hoverColor: palette.hovered,
      highlightColor: palette.pressed,
      splashColor: palette.pressed,
      focusColor: palette.focusRing,
      shadowColor: palette.shadowAt(palette.isDark ? .5 : .14),
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
            brightness: palette.brightness,
          ).copyWith(
            primary: green,
            onPrimary: palette.onAccent,
            primaryContainer: palette.softGreen,
            onPrimaryContainer: ink,
            error: palette.danger,
            onError: palette.onAccent,
            errorContainer: palette.dangerSoft,
            onErrorContainer: palette.danger,
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
        bodyMedium: const TextStyle(fontSize: textBase, height: leadingNormal),
        bodyLarge: const TextStyle(fontSize: textBase, height: leadingNormal),
        bodySmall: TextStyle(
          fontSize: textXs,
          height: leadingCompact,
          color: muted,
        ),
        titleLarge: const TextStyle(
          fontSize: textXl,
          height: leadingTight,
          fontWeight: weightLabel,
        ),
        titleMedium: const TextStyle(
          fontSize: textBase,
          height: leadingCompact,
          fontWeight: weightLabel,
        ),
        labelLarge: const TextStyle(
          fontSize: textSm,
          height: leadingTight,
          fontWeight: weightLabel,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: elevationFlat,
        centerTitle: false,
        titleSpacing: space4,
        titleTextStyle: TextStyle(
          fontSize: textXl,
          height: leadingTight,
          fontWeight: weightLabel,
          color: ink,
          fontFamilyFallback: fontFallback,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: palette.surface,
        indicatorColor: palette.selected,
        elevation: elevationFlat,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: outline,
        enabledBorder: outline,
        focusedBorder: OutlineInputBorder(
          borderRadius: fieldRadius,
          borderSide: BorderSide(color: green, width: strokeFocus),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: fieldRadius,
          borderSide: BorderSide(color: palette.danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: fieldRadius,
          borderSide: BorderSide(color: palette.danger, width: strokeFocus),
        ),
        disabledBorder: outline,
        filled: true,
        fillColor: input,
        constraints: const BoxConstraints(minHeight: fieldHeight),
        contentPadding: insetField,
        hintStyle: TextStyle(fontSize: textSm, color: muted),
        labelStyle: TextStyle(fontSize: textBase, color: muted),
        errorStyle: TextStyle(fontSize: textXs, color: palette.danger),
      ),
      cardTheme: CardThemeData(
        elevation: elevationFlat,
        color: palette.surface,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: cardRadius,
          side: BorderSide(color: border),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(88, controlHeight),
          shape: buttonShape,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: space2),
          textStyle: label,
          foregroundColor: palette.onAccent,
          backgroundColor: green,
          disabledBackgroundColor: palette.disabledFill,
          disabledForegroundColor: palette.disabledInk,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(88, controlHeight),
          shape: buttonShape,
          side: BorderSide(color: border),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: space2),
          textStyle: label,
          foregroundColor: green,
          disabledForegroundColor: palette.disabledInk,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, controlHeight),
          shape: buttonShape,
          padding: const EdgeInsets.symmetric(
            horizontal: space2,
            vertical: space1,
          ),
          textStyle: label,
          disabledForegroundColor: palette.disabledInk,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(rowHeight, rowHeight),
          padding: const EdgeInsets.all(space1),
          disabledForegroundColor: palette.disabledInk,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        elevation: elevationModal,
        shape: RoundedRectangleBorder(
          borderRadius: panelRadius,
          side: BorderSide(color: border),
        ),
        titleTextStyle: TextStyle(
          fontSize: textXl,
          height: leadingTight,
          fontWeight: weightLabel,
          color: ink,
          fontFamilyFallback: fontFallback,
        ),
        contentTextStyle: TextStyle(
          fontSize: textBase,
          height: leadingNormal,
          color: ink,
          fontFamilyFallback: fontFallback,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: palette.surface,
        surfaceTintColor: Colors.transparent,
        elevation: elevationOverlay,
        shape: RoundedRectangleBorder(
          borderRadius: fieldRadius,
          side: BorderSide(color: border),
        ),
        textStyle: TextStyle(
          fontSize: textBase,
          height: leadingCompact,
          color: ink,
          fontFamilyFallback: fontFallback,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        elevation: elevationOverlay,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(radiusPanel),
          ),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(
          horizontal: space3,
          vertical: space1,
        ),
        minVerticalPadding: space2,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: fieldRadius),
      ),
      dividerTheme: DividerThemeData(
        color: border,
        thickness: stroke,
        space: space4,
      ),
    );
  }

  static Size editorSize(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final width = math.min(editorMaxWidth, viewport.width - space5);
    final available =
        viewport.height - MediaQuery.viewInsetsOf(context).bottom - space7;
    return Size(
      width,
      math.min((width - space6) * .75 + 128, math.max(160, available)),
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
    // 2px vertical padding keeps the 44px drag area inside a 48px row.
    padding: const EdgeInsets.symmetric(horizontal: Ui.space2, vertical: 2),
    child: SizedBox(
      height: Ui.touch,
      child: TextButtonTheme(
        data: TextButtonThemeData(
          style: TextButton.styleFrom(
            minimumSize: const Size(Ui.rowHeight, 36),
            padding: const EdgeInsets.symmetric(horizontal: Ui.space1),
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
          fontSize: Ui.textSm,
          height: Ui.leadingCompact,
          fontWeight: Ui.weightLabel,
          color: Ui.colors(context).textSecondary,
        ),
      ),
      const SizedBox(height: Ui.space1),
      Semantics(label: label, child: child),
    ],
  );
}

class UiSection extends StatelessWidget {
  const UiSection({
    super.key,
    required this.title,
    required this.children,
    this.padding = Ui.space4,
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
          const SizedBox(height: Ui.space4),
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
    color: Ui.colors(context).surfaceMuted,
    shape: RoundedRectangleBorder(
      borderRadius: Ui.cardRadius,
      side: BorderSide(color: Ui.colors(context).line),
    ),
    clipBehavior: Clip.antiAlias,
    child: AppExpansionTile(
      key: key,
      title: Text(
        title,
        style: const TextStyle(fontSize: Ui.textSm, fontWeight: Ui.weightLabel),
      ),
      tilePadding: const EdgeInsets.symmetric(
        horizontal: Ui.space3,
        vertical: Ui.space1,
      ),
      childrenPadding: const EdgeInsets.fromLTRB(
        Ui.space3,
        0,
        Ui.space3,
        Ui.space3,
      ),
      shape: const Border(),
      collapsedShape: const Border(),
      children: children,
    ),
  ),
);

/// One-line segmented caption: shrinks to the segment, never wraps.
class _SegmentLabel extends StatelessWidget {
  const _SegmentLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    child: Text(text, maxLines: 1, softWrap: false),
  );
}

class AppearancePicker extends StatelessWidget {
  const AppearancePicker({super.key});
  @override
  Widget build(BuildContext context) {
    final settings = AppearanceScope.maybeOf(context);
    if (settings == null) return const SizedBox.shrink();
    final value = settings.value;
    final resolved = value.resolve(Theme.of(context).brightness);
    Future<void> save({AppearanceMode? mode, AccentColor? accent}) async {
      try {
        await settings.set(mode: mode, accent: accent);
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.maybeOf(context)
              ?.showSnackBar(const SnackBar(content: Text('外观未保存，请重试')));
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<AppearanceMode>(
          key: const ValueKey('appearance-mode'),
          showSelectedIcon: false,
          // Labels never wrap: a wide system font (or a large text scale) shrinks the
          // caption instead of breaking "跟随系统" across two lines.
          style: const ButtonStyle(
            padding: WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: Ui.space2),
            ),
          ),
          segments: const [
            ButtonSegment(
              value: AppearanceMode.light,
              label: _SegmentLabel('亮色'),
            ),
            ButtonSegment(
              value: AppearanceMode.dark,
              label: _SegmentLabel('暗色'),
            ),
            ButtonSegment(
              value: AppearanceMode.neutral,
              label: _SegmentLabel('中性'),
            ),
            ButtonSegment(
              value: AppearanceMode.system,
              label: _SegmentLabel('跟随系统'),
            ),
          ],
          selected: {value.mode},
          onSelectionChanged: (selected) => save(mode: selected.single),
        ),
        const SizedBox(height: Ui.space3),
        Wrap(
          spacing: Ui.space1,
          runSpacing: Ui.space1,
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
                    radius: Ui.space4,
                    child: SizedBox.square(
                      dimension: Ui.touch,
                      child: Center(
                        child: Container(
                          width: Ui.space5,
                          height: Ui.space5,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: UiPalette.from(
                              resolved.copyWith(accent: accent),
                            ).green,
                          ),
                          // Always mounted: scale and opacity carry the
                          // check in and out without touching the swatch size.
                          child: AnimatedScale(
                            scale: value.accent == accent ? 1 : 0,
                            duration: Ui.durationFast,
                            curve: Ui.ease,
                            child: AnimatedOpacity(
                              opacity: value.accent == accent ? 1 : 0,
                              duration: Ui.durationFast,
                              curve: Ui.ease,
                              child: AppIcon(
                                Icons.done,
                                size: Ui.iconSm + 2,
                                color: UiPalette.from(resolved).onAccent,
                              ),
                            ),
                          ),
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
      padding: Ui.insetPanel,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(
            icon,
            size: Ui.iconLg,
            color: Ui.colors(context).textSecondary,
          ),
          const SizedBox(height: Ui.space3),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: Ui.textBase,
              color: Ui.colors(context).muted,
            ),
          ),
          if (action != null) ...[const SizedBox(height: Ui.space3), action!],
        ],
      ),
    ),
  );
}
