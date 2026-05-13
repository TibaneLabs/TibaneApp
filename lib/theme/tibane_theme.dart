import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Tibane Labs design system - matching tibane.net theme
class TibaneColors {
  // Core palette
  static const black = Color(0xFF030305);
  static const dark = Color(0xFF08080D);
  static const darker = Color(0xFF0E0E16);
  static const card = Color(0xFF111119);
  static const cardHover = Color(0xFF181823);
  static const surface = Color(0xFF1A1A26);

  // Brand
  static const orange = Color(0xFFFF6B2C);
  static const gold = Color(0xFFFFAD42);
  static const amber = Color(0xFFFFD666);

  // Accents
  static const purple = Color(0xFFA855F7);
  static const pink = Color(0xFFF472B6);
  static const cyan = Color(0xFF22D3A7);
  static const blue = Color(0xFF38BDF8);

  // Text
  static const text = Color(0xFFEAEAF0);
  static const textMuted = Color(0xFF7B7B96);
  static const textDim = Color(0xFF4A4A62);

  // Borders
  static const border = Color(0x0DFFFFFF); // 5% white
  static const borderHover = Color(0x1AFFFFFF); // 10% white

  // Gradients
  static const brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [orange, gold, amber],
  );

  static const purpleGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [purple, pink],
  );

  // Semantic
  static const success = cyan;
  static const error = Color(0xFFEF4444);
  static const warning = gold;
}

class TibaneTheme {
  static ThemeData get darkTheme {
    final textTheme = GoogleFonts.dmSansTextTheme(ThemeData.dark().textTheme);

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: TibaneColors.black,
      colorScheme: const ColorScheme.dark(
        primary: TibaneColors.orange,
        secondary: TibaneColors.gold,
        surface: TibaneColors.card,
        error: TibaneColors.error,
        onPrimary: TibaneColors.black,
        onSecondary: TibaneColors.black,
        onSurface: TibaneColors.text,
        onError: Colors.white,
      ),
      textTheme: textTheme.copyWith(
        displayLarge: textTheme.displayLarge?.copyWith(
          color: TibaneColors.text,
          fontWeight: FontWeight.w700,
          letterSpacing: -1.5,
        ),
        displayMedium: textTheme.displayMedium?.copyWith(
          color: TibaneColors.text,
          fontWeight: FontWeight.w700,
          letterSpacing: -1.0,
        ),
        headlineLarge: textTheme.headlineLarge?.copyWith(
          color: TibaneColors.text,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        headlineMedium: textTheme.headlineMedium?.copyWith(
          color: TibaneColors.text,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        titleLarge: textTheme.titleLarge?.copyWith(
          color: TibaneColors.text,
          fontWeight: FontWeight.w600,
        ),
        titleMedium: textTheme.titleMedium?.copyWith(
          color: TibaneColors.text,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: textTheme.bodyLarge?.copyWith(
          color: TibaneColors.text,
          height: 1.6,
        ),
        bodyMedium: textTheme.bodyMedium?.copyWith(
          color: TibaneColors.textMuted,
          height: 1.6,
        ),
        labelLarge: textTheme.labelLarge?.copyWith(
          color: TibaneColors.text,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
        labelSmall: textTheme.labelSmall?.copyWith(
          color: TibaneColors.textMuted,
          letterSpacing: 1.0,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: TibaneColors.black.withValues(alpha: 0.8),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.dmSans(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: TibaneColors.text,
        ),
        iconTheme: const IconThemeData(color: TibaneColors.text),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: TibaneColors.dark,
        selectedItemColor: TibaneColors.orange,
        unselectedItemColor: TibaneColors.textDim,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: TibaneColors.card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: TibaneColors.border),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: TibaneColors.orange,
          foregroundColor: TibaneColors.black,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: GoogleFonts.dmSans(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: TibaneColors.orange,
          side: BorderSide(color: TibaneColors.orange.withValues(alpha: 0.4)),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: GoogleFonts.dmSans(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: TibaneColors.darker,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: TibaneColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: TibaneColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: TibaneColors.orange),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        hintStyle: GoogleFonts.dmSans(
          color: TibaneColors.textDim,
          fontSize: 14,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: TibaneColors.border,
        thickness: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: TibaneColors.card,
        contentTextStyle: GoogleFonts.dmSans(color: TibaneColors.text),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        behavior: SnackBarBehavior.floating,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: TibaneColors.orange,
        unselectedLabelColor: TibaneColors.textMuted,
        indicatorColor: TibaneColors.orange,
        labelStyle: GoogleFonts.dmSans(
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
        unselectedLabelStyle: GoogleFonts.dmSans(
          fontWeight: FontWeight.w400,
          fontSize: 14,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: TibaneColors.darker,
        selectedColor: TibaneColors.orange.withValues(alpha: 0.15),
        side: const BorderSide(color: TibaneColors.border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
        labelStyle: GoogleFonts.spaceMono(
          fontSize: 11,
          letterSpacing: 0.5,
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: TibaneColors.orange,
        linearTrackColor: TibaneColors.darker,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: TibaneColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: TibaneColors.border),
        ),
      ),
    );
  }
}

/// Mono text style for addresses, amounts, code
TextStyle monoStyle({double fontSize = 13, Color color = TibaneColors.text}) {
  return GoogleFonts.spaceMono(
    fontSize: fontSize,
    color: color,
    letterSpacing: -0.3,
  );
}

/// Serif italic for decorative accents
TextStyle serifStyle({double fontSize = 18, Color color = TibaneColors.textMuted}) {
  return GoogleFonts.instrumentSerif(
    fontSize: fontSize,
    fontStyle: FontStyle.italic,
    color: color,
  );
}
