import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../countries.dart';
import '../theme.dart';
import 'common.dart';

/// A country-code picker joined to a national-number input.
///
/// Pasting a full international number ("+44 7911 123456") selects the
/// matching country and keeps only the national part, like the web
/// Playground's field.
class PhoneNumberField extends StatefulWidget {
  const PhoneNumberField({
    super.key,
    required this.iso,
    required this.number,
    required this.onIsoChanged,
    required this.onNumberChanged,
    required this.label,
    this.placeholder = '',
    this.large = false,
    this.accent = false,
    this.onSubmitted,
  });

  final String iso;
  final String number;
  final ValueChanged<String> onIsoChanged;
  final ValueChanged<String> onNumberChanged;
  final String label;
  final String placeholder;
  final bool large;
  final bool accent;
  final VoidCallback? onSubmitted;

  @override
  State<PhoneNumberField> createState() => _PhoneNumberFieldState();
}

class _PhoneNumberFieldState extends State<PhoneNumberField> {
  late final TextEditingController _text = TextEditingController(text: widget.number);

  @override
  void didUpdateWidget(PhoneNumberField old) {
    super.didUpdateWidget(old);
    // Keep the field in step when the number changes from outside (the
    // keypad, a pasted +code moving into the picker). A change that only
    // follows what was typed leaves the text alone: its "+", spaces and
    // brackets stay, and the cursor stays where it is.
    if (widget.number != old.number && widget.number != _text.text.replaceAll(RegExp(r'\D'), '')) {
      _text.value = TextEditingValue(
        text: widget.number,
        selection: TextSelection.collapsed(offset: widget.number.length),
      );
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _onChanged(String raw) {
    if (raw.trim().startsWith('+')) {
      final split = splitE164(raw, currentIso: widget.iso);
      if (split != null) {
        if (split.country.iso != widget.iso) widget.onIsoChanged(split.country.iso);
        widget.onNumberChanged(split.national);
      }
      // No calling code yet ("+", "+4"): keep typing.
      return;
    }
    widget.onNumberChanged(raw.replaceAll(RegExp(r'\D'), ''));
  }

  Future<void> _pickCountry() async {
    final picked = await showCountryPicker(context, selectedIso: widget.iso);
    if (picked != null) widget.onIsoChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final pg = context.pg;
    final country = findCountry(widget.iso);
    final size = widget.large ? 20.0 : 15.0;
    final color = widget.accent ? pg.accent : pg.text;
    return Container(
      decoration: BoxDecoration(
        color: pg.field,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: widget.accent ? pg.accent.withValues(alpha: 0.45) : pg.border, width: 1.5),
      ),
      child: Row(
        children: <Widget>[
          InkWell(
            onTap: _pickCountry,
            borderRadius: const BorderRadius.horizontal(left: Radius.circular(14)),
            child: Semantics(
              button: true,
              label: '${widget.label} country code, ${country.name} ${country.dial}',
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: widget.large ? 14 : 11),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(country.iso,
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: size * 0.8, color: pg.muted)),
                    const SizedBox(width: 6),
                    Text(country.dial,
                        style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: size,
                            fontWeight: FontWeight.w600,
                            color: color)),
                    Icon(Icons.expand_more, size: 18, color: pg.faint),
                  ],
                ),
              ),
            ),
          ),
          Container(width: 1, height: widget.large ? 30 : 24, color: pg.border),
          Expanded(
            child: Semantics(
              label: widget.label,
              child: TextField(
                controller: _text,
                keyboardType: TextInputType.phone,
                textInputAction: widget.onSubmitted != null ? TextInputAction.go : TextInputAction.next,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.allow(RegExp(r'[\d+\s()-]')),
                ],
                onChanged: _onChanged,
                onSubmitted: (_) => widget.onSubmitted?.call(),
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: size,
                  fontWeight: FontWeight.w600,
                  color: color,
                  letterSpacing: 0.5,
                ),
                decoration: InputDecoration(
                  hintText: widget.placeholder,
                  labelText: null,
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: widget.large ? 16 : 12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A searchable country list. Returns the chosen ISO code, or null.
Future<String?> showCountryPicker(BuildContext context, {required String selectedIso}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: context.pg.panel,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => _CountryPickerSheet(selectedIso: selectedIso),
  );
}

class _CountryPickerSheet extends StatefulWidget {
  const _CountryPickerSheet({required this.selectedIso});

  final String selectedIso;

  @override
  State<_CountryPickerSheet> createState() => _CountryPickerSheetState();
}

class _CountryPickerSheetState extends State<_CountryPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final pg = context.pg;
    final results = searchCountries(_query);
    final showPopular = _query.trim().isEmpty;
    final popular = popularIsos.map(findCountry).toList();

    Widget tile(Country c) => ListTile(
          dense: true,
          leading: Text(c.flag, style: const TextStyle(fontSize: 20)),
          title: Text(c.name, style: TextStyle(color: pg.text)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(c.dial, style: TextStyle(fontFamily: 'monospace', color: pg.muted)),
              if (c.iso == widget.selectedIso) ...<Widget>[
                const SizedBox(width: 8),
                Icon(Icons.check, size: 18, color: pg.accent),
              ],
            ],
          ),
          onTap: () => Navigator.of(context).pop(c.iso),
        );

    Widget heading(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(text,
              style: TextStyle(
                  fontSize: 10, letterSpacing: 1.6, fontWeight: FontWeight.w700, color: pg.faint)),
        );

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.8,
      child: Column(
        children: <Widget>[
          const SizedBox(height: 8),
          const SheetHandle(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                hintText: 'Search country, code or +dial',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              children: <Widget>[
                if (showPopular) ...<Widget>[
                  heading('POPULAR'),
                  ...popular.map(tile),
                  heading('ALL COUNTRIES'),
                ],
                if (results.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('No country matches "$_query"',
                        textAlign: TextAlign.center, style: TextStyle(color: pg.muted)),
                  ),
                ...results.map(tile),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
