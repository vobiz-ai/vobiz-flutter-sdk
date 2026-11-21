import 'package:flutter/material.dart';

import '../playground_controller.dart';
import '../theme.dart';

/// The small uppercase label above a field or section.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final pg = context.pg;
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(text.toUpperCase(),
                style: TextStyle(
                    fontSize: 10, letterSpacing: 1.6, fontWeight: FontWeight.w700, color: pg.faint)),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// An (i) icon that explains a field when tapped.
class InfoTip extends StatelessWidget {
  const InfoTip({super.key, required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final pg = context.pg;
    return Semantics(
      container: true,
      button: true,
      label: 'About $title',
      child: InkResponse(
        radius: 18,
        onTap: () => showDialog<void>(
          context: context,
          // The dialog's own context: the tip may be gone from the tree (an
          // incoming call replaced its screen) before "Got it" is tapped.
          builder: (dialogContext) => AlertDialog(
            backgroundColor: pg.panel,
            title: Text(title, style: TextStyle(color: pg.accent, fontSize: 16, fontWeight: FontWeight.w700)),
            content: Text(message, style: TextStyle(color: pg.text, height: 1.45)),
            actions: <Widget>[
              TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Got it')),
            ],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(Icons.info_outline, size: 15, color: pg.faint),
        ),
      ),
    );
  }
}

/// The coloured dot and text that say whether the phone is registered.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.status, required this.text});

  final PhoneStatus status;
  final String text;

  @override
  Widget build(BuildContext context) {
    final pg = context.pg;
    final dot = switch (status) {
      PhoneStatus.online => pg.accent,
      PhoneStatus.inCall => pg.success,
      PhoneStatus.ringing => pg.warning,
      PhoneStatus.connecting => pg.muted,
      PhoneStatus.error => pg.danger,
      PhoneStatus.offline => pg.faint,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: pg.field,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: pg.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: pg.muted)),
          ),
        ],
      ),
    );
  }
}

/// A rounded, bordered panel.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final pg = context.pg;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: pg.panel,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: pg.border),
      ),
      child: child,
    );
  }
}

/// A small coloured badge: "Received", "Sent", "REC", a count.
class Chip2 extends StatelessWidget {
  const Chip2(this.text, {super.key, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.5, color: color)),
    );
  }
}

/// Header name/value pairs in monospace.
class HeaderTable extends StatelessWidget {
  const HeaderTable(this.headers, {super.key});

  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    final pg = context.pg;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: headers.entries
          .map((e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 1.5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(e.key, style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: pg.muted)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SelectableText(e.value,
                          style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: pg.text)),
                    ),
                  ],
                ),
              ))
          .toList(),
    );
  }
}

/// Light, dark or follow the system, as the Playground's theme toggle offers.
class ThemeToggle extends StatelessWidget {
  const ThemeToggle({super.key, required this.mode, required this.onChanged});

  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final pg = context.pg;
    Widget button(ThemeMode value, IconData icon, String label) {
      final selected = value == mode;
      return Tooltip(
        message: label,
        child: InkResponse(
          onTap: () => onChanged(value),
          radius: 18,
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: selected ? pg.accentSoft : Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 16, color: selected ? pg.accent : pg.faint),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: pg.field,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: pg.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          button(ThemeMode.light, Icons.light_mode_outlined, 'Light'),
          button(ThemeMode.dark, Icons.dark_mode_outlined, 'Dark'),
          button(ThemeMode.system, Icons.desktop_windows_outlined, 'System'),
        ],
      ),
    );
  }
}

/// The tappable header of a collapsible section: icon, upper-case title,
/// chips, and a chevron that says whether it is [open].
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.icon,
    required this.title,
    required this.open,
    required this.onTap,
    this.chips = const <Widget>[],
  });

  final IconData icon;
  final String title;
  final bool open;
  final VoidCallback onTap;
  final List<Widget> chips;

  @override
  Widget build(BuildContext context) {
    final pg = context.pg;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 14, color: pg.accent.withValues(alpha: 0.8)),
            const SizedBox(width: 8),
            Text(title, style: TextStyle(fontSize: 10, letterSpacing: 1.6, fontWeight: FontWeight.w700, color: pg.faint)),
            for (var i = 0; i < chips.length; i++) ...<Widget>[SizedBox(width: i == 0 ? 8 : 6), chips[i]],
            const Spacer(),
            Icon(open ? Icons.expand_less : Icons.expand_more, size: 18, color: pg.faint),
          ],
        ),
      ),
    );
  }
}

/// The drag handle at the top of a bottom sheet.
class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(color: context.pg.border, borderRadius: BorderRadius.circular(2)),
      ),
    );
  }
}

/// A bottom sheet in the Playground's style that stays above the keyboard
/// and rebuilds whenever [listenable] changes.
Future<void> showPlaygroundSheet(BuildContext context, Listenable listenable, WidgetBuilder builder) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: context.pg.panel,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    // The sheet's own context: the opener's sits in the Scaffold body, which
    // has the keyboard inset removed already.
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
      child: ListenableBuilder(listenable: listenable, builder: (context, _) => builder(context)),
    ),
  );
}
