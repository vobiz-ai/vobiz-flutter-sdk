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
          if (trailing != null) trailing!,
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
    return InkResponse(
      radius: 18,
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: pg.panel,
          title: Text(title, style: TextStyle(color: pg.accent, fontSize: 16, fontWeight: FontWeight.w700)),
          content: Text(message, style: TextStyle(color: pg.text, height: 1.45)),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Got it')),
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(Icons.info_outline, size: 15, color: pg.faint),
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
          Text(text.toUpperCase(),
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: pg.muted)),
        ],
      ),
    );
  }
}

/// A rounded, bordered panel.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(20)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final pg = context.pg;
    return Container(
      padding: padding,
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
