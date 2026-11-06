import 'package:flutter/material.dart';

/// Colors drawn from the sage-to-mist gradient in docs/logo.png.
abstract final class NeuroxBrand {
  static const teal = Color(0xff397f80);
  static const sage = Color(0xffbdd6a5);
  static const mist = Color(0xff7eafc7);
  static const ink = Color(0xff263f43);
  static const paper = Color(0xfff5f9f7);
  static const markAsset = 'assets/branding/neurox-mark-transparent.png';

  static ThemeData theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final colors = ColorScheme.fromSeed(seedColor: teal, brightness: brightness)
        .copyWith(
          primary: dark ? const Color(0xffa5d4cf) : teal,
          onPrimary: dark ? const Color(0xff123d3d) : Colors.white,
          primaryContainer: dark
              ? const Color(0xff244d4b)
              : const Color(0xffe1efea),
          onPrimaryContainer: dark ? const Color(0xffd7ede6) : ink,
          secondary: dark ? const Color(0xffa9ccdf) : const Color(0xff48758b),
          secondaryContainer: dark
              ? const Color(0xff284652)
              : const Color(0xffe3eff5),
          onSecondaryContainer: dark
              ? const Color(0xffdceef5)
              : const Color(0xff294653),
          tertiary: dark ? sage : const Color(0xff587244),
          surface: dark ? const Color(0xff192c2e) : Colors.white,
          onSurface: dark ? const Color(0xffe1ece8) : ink,
          onSurfaceVariant: dark
              ? const Color(0xffb7cbc5)
              : const Color(0xff566d68),
          outline: dark ? const Color(0xff78918a) : const Color(0xff78918b),
          outlineVariant: dark
              ? const Color(0xff354d49)
              : const Color(0xffdce8e2),
        );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(24),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: dark ? const Color(0xff112123) : paper,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: colors.onSurface,
        titleTextStyle: TextStyle(
          color: colors.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: colors.surface,
        surfaceTintColor: Colors.transparent,
        shape: shape.copyWith(side: BorderSide(color: colors.outlineVariant)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 50),
          side: BorderSide(color: colors.outlineVariant),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 18,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colors.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colors.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colors.primary, width: 2),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: colors.primaryContainer,
        elevation: 0,
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: BorderSide(color: colors.outlineVariant),
        selectedColor: colors.primaryContainer,
      ),
      dialogTheme: DialogThemeData(
        shape: shape,
        backgroundColor: colors.surface,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: colors.primary),
      listTileTheme: ListTileThemeData(iconColor: colors.primary, shape: shape),
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant,
        thickness: 1,
      ),
    );
  }

  static LinearGradient wash(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const LinearGradient(colors: [Color(0xff25483f), Color(0xff203e49)])
      : const LinearGradient(colors: [Color(0xffedf4e7), Color(0xffe6f1f5)]);
}

class NeuroxMark extends StatelessWidget {
  const NeuroxMark({super.key, this.size = 64});
  final double size;
  @override
  Widget build(BuildContext context) => Image.asset(
    NeuroxBrand.markAsset,
    width: size,
    height: size,
    fit: BoxFit.contain,
    filterQuality: FilterQuality.high,
    excludeFromSemantics: true,
  );
}

class NeuroxWelcome extends StatelessWidget {
  const NeuroxWelcome({super.key, required this.title, required this.subtitle});
  final String title, subtitle;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      gradient: NeuroxBrand.wash(context),
      borderRadius: BorderRadius.circular(28),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'NeuroX',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                title,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        const NeuroxMark(size: 68),
      ],
    ),
  );
}
