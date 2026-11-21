import 'package:flutter/material.dart';

import '../theme.dart';

/// A phone keypad. Before a call it types digits; during one it sends DTMF.
class Keypad extends StatelessWidget {
  const Keypad({super.key, required this.onKey});

  final ValueChanged<String> onKey;

  static const List<String> _keys = <String>['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'];

  @override
  Widget build(BuildContext context) {
    final pg = context.pg;
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 2.6,
      children: _keys.map((key) {
        return Material(
          color: pg.field,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => onKey(key),
            child: Semantics(
              button: true,
              label: 'Key $key',
              child: Center(
                child: Text(key, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: pg.text)),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
