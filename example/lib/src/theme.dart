import 'package:flutter/material.dart';

/// Colours the Playground screens use beyond Material's own scheme.
@immutable
class PlaygroundColors extends ThemeExtension<PlaygroundColors> {
  const PlaygroundColors({
    required this.page,
    required this.panel,
    required this.field,
    required this.border,
    required this.text,
    required this.muted,
    required this.faint,
    required this.accent,
    required this.accentSoft,
    required this.success,
    required this.danger,
    required this.info,
    required this.warning,
  });

  final Color page;
  final Color panel;
  final Color field;
  final Color border;
  final Color text;
  final Color muted;
  final Color faint;
  final Color accent;
  final Color accentSoft;
  final Color success;
  final Color danger;
  final Color info;
  final Color warning;

  static const PlaygroundColors dark = PlaygroundColors(
    page: Color(0xFF0A0C10),
    panel: Color(0xFF141720),
    field: Color(0xFF0E1016),
    border: Color(0xFF252A3A),
    text: Color(0xFFF4F4F5),
    muted: Color(0xFF8B93A5),
    faint: Color(0xFF5B6275),
    accent: Color(0xFFEA580C),
    accentSoft: Color(0x26EA580C),
    success: Color(0xFF34D399),
    danger: Color(0xFFF87171),
    info: Color(0xFF38BDF8),
    warning: Color(0xFFFBBF24),
  );

  static const PlaygroundColors light = PlaygroundColors(
    page: Color(0xFFF4F4F5),
    panel: Color(0xFFFFFFFF),
    field: Color(0xFFF7F7F8),
    border: Color(0xFFE4E4E7),
    text: Color(0xFF18181B),
    muted: Color(0xFF52525B),
    faint: Color(0xFF8A8A93),
    accent: Color(0xFFEA580C),
    accentSoft: Color(0x1FEA580C),
    success: Color(0xFF059669),
    danger: Color(0xFFDC2626),
    info: Color(0xFF0284C7),
    warning: Color(0xFFB45309),
  );

  @override
  PlaygroundColors copyWith() => this;

  @override
  PlaygroundColors lerp(ThemeExtension<PlaygroundColors>? other, double t) =>
      t < 0.5 ? this : (other as PlaygroundColors? ?? this);
}

/// Button fills for Call / Answer and Hang up. The same in both themes: deep
/// enough that white text on them stays readable on a dark background too.
const Color callGreen = Color(0xFF16A34A);
const Color hangupRed = Color(0xFFDC2626);

extension PlaygroundTheme on BuildContext {
  PlaygroundColors get pg => Theme.of(this).extension<PlaygroundColors>()!;
}

ThemeData buildTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? PlaygroundColors.dark : PlaygroundColors.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: c.accent,
    brightness: brightness,
    primary: c.accent,
    surface: c.panel,
    error: c.danger,
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.page,
    extensions: <ThemeExtension<dynamic>>[c],
  );
  OutlineInputBorder outline(Color color) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: color, width: 1.2),
      );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: c.text, displayColor: c.text),
    dividerColor: c.border,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.field,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      hintStyle: TextStyle(color: c.faint),
      labelStyle: TextStyle(color: c.muted),
      border: outline(c.border),
      enabledBorder: outline(c.border),
      focusedBorder: outline(c.accent),
      errorBorder: outline(c.danger),
      focusedErrorBorder: outline(c.danger),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.muted,
        side: BorderSide(color: c.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? c.accent : null),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.panel,
      indicatorColor: c.accentSoft,
      labelTextStyle: WidgetStatePropertyAll(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.muted)),
    ),
  );
}
