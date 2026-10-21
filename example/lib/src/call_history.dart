import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How a call ended, as the call log shows it.
enum CallOutcome {
  /// Answered on this phone.
  answered,

  /// Rang here, nobody answered anywhere, the caller gave up.
  missed,

  /// Declined (on this phone or another of the user's devices).
  declined,

  /// Another phone, browser or device took it. Not a missed call.
  answeredElsewhere,

  /// Arrived while this phone was on another call.
  busy,

  /// Placed from this phone.
  outgoing,

  /// Placed from this phone and failed before connecting.
  failed,
}

extension CallOutcomeText on CallOutcome {
  String get label => switch (this) {
        CallOutcome.answered => 'Answered',
        CallOutcome.missed => 'Missed',
        CallOutcome.declined => 'Declined',
        CallOutcome.answeredElsewhere => 'Answered elsewhere',
        CallOutcome.busy => 'Missed (on another call)',
        CallOutcome.outgoing => 'Outgoing',
        CallOutcome.failed => 'Failed',
      };

  /// Outcomes that deserve a "Missed call" notification.
  bool get notifies => this == CallOutcome.missed || this == CallOutcome.busy;
}

/// Whether a SIP end reason says another device answered: a CANCEL with
/// `Reason: SIP;cause=200` (the SDK reports it as "… (SIP 200)"), or a
/// reason that says "elsewhere".
bool reasonMeansAnsweredElsewhere(String? reason) {
  final r = (reason ?? '').toLowerCase();
  return r.contains('(sip 200)') || r.contains('cause=200') || r.contains('elsewhere');
}

/// One call in the log.
@immutable
class CallRecord {
  const CallRecord({
    required this.id,
    required this.inbound,
    required this.party,
    required this.at,
    required this.outcome,
    this.duration = Duration.zero,
  });

  static CallRecord? fromJson(Map<String, dynamic> json) {
    final outcome = CallOutcome.values.where((o) => o.name == json['outcome']).firstOrNull;
    final at = DateTime.tryParse('${json['at'] ?? ''}');
    if (outcome == null || at == null) return null;
    return CallRecord(
      id: '${json['id'] ?? ''}',
      inbound: json['inbound'] == true,
      party: '${json['party'] ?? ''}',
      at: at,
      outcome: outcome,
      duration: Duration(seconds: (json['seconds'] as num?)?.toInt() ?? 0),
    );
  }

  /// The bridge's call id (PushRef) when there is one, else the SIP Call-ID.
  final String id;
  final bool inbound;

  /// The other party's number or SIP user.
  final String party;
  final DateTime at;
  final CallOutcome outcome;
  final Duration duration;

  Map<String, Object> toJson() => <String, Object>{
        'id': id,
        'inbound': inbound,
        'party': party,
        'at': at.toIso8601String(),
        'outcome': outcome.name,
        'seconds': duration.inSeconds,
      };
}

/// A simple local call log, kept in SharedPreferences: the newest 50 calls,
/// one entry per call.
class CallHistory extends ChangeNotifier {
  static const String storageKey = 'vobiz_playground_call_history';
  static const int maxEntries = 50;

  SharedPreferences? _prefs;
  final List<CallRecord> _records = <CallRecord>[];

  /// Newest first.
  List<CallRecord> get records => List<CallRecord>.unmodifiable(_records);

  void load(SharedPreferences prefs) {
    _prefs = prefs;
    _records.clear();
    try {
      final saved = prefs.getString(storageKey);
      if (saved != null) {
        for (final item in (jsonDecode(saved) as List).whereType<Map<String, dynamic>>()) {
          final record = CallRecord.fromJson(item);
          if (record != null) _records.add(record);
        }
      }
    } catch (_) {
      // A damaged log is not worth failing over.
    }
    notifyListeners();
  }

  CallRecord? byId(String id) => _records.where((r) => r.id == id).firstOrNull;

  /// Records how [record]'s call ended. Returns false (and changes nothing)
  /// when that call is already in the log, so a call is logged and notified
  /// once however many signals report its end.
  bool add(CallRecord record) {
    if (byId(record.id) != null) return false;
    _records.insert(0, record);
    if (_records.length > maxEntries) _records.removeRange(maxEntries, _records.length);
    _save();
    notifyListeners();
    return true;
  }

  void clear() {
    _records.clear();
    _save();
    notifyListeners();
  }

  void _save() {
    _prefs?.setString(storageKey, jsonEncode(_records.map((r) => r.toJson()).toList()));
  }
}
