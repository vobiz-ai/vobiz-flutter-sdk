import 'package:flutter/material.dart';

import '../theme.dart';

/// A phone keypad. Before a call it types digits; during one it sends DTMF.
class Keypad extends StatelessWidget {
  const Keypad({super.key, required this.onKey, this.compact = false});

  final ValueChanged<String> onKey;
  final bool compact;

  static const List<(String, String)> _keys = <(String, String)>[
    ('1', ''), ('2', 'ABC'), ('3', 'DEF'),
    ('4', 'GHI'), ('5', 'JKL'), ('6', 'MNO'),
    ('7', 'PQRS'), ('8', 'TUV'), ('9', 'WXYZ'),
    ('*', ''), ('0', '+'), ('#', ''),
  ];

  @override
  Widget build(BuildContext context) {
    final pg = context.pg;
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: compact ? 2.6 : 2.0,
      children: _keys.map((k) {
        return Material(
          color: pg.field,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => onKey(k.$1),
            child: Semantics(
              button: true,
              label: 'Key ${k.$1}',
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Text(k.$1,
                      style: TextStyle(
                          fontSize: compact ? 18 : 22, fontWeight: FontWeight.w600, color: pg.text)),
                  if (k.$2.isNotEmpty && !compact)
                    Text(k.$2, style: TextStyle(fontSize: 8, letterSpacing: 1.4, color: pg.faint)),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
