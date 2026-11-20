import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/vobiz_client.dart';
import '../errors/vobiz_exception.dart';
import '../events/call_event.dart';
import '../state/call_state.dart';
import '../utils/sip_text.dart';

/// Where a conference participant is.
enum VobizParticipantStatus {
  /// On the way into the room: the call's own two sides just after it
  /// became a conference, a dialled person who answered, or someone coming
  /// back from hold.
  connecting,

  /// Being dialled.
  dialing,

  /// In the room.
  joined,

  /// Out of the room, hearing hold music, until resumed.
  onHold,

  /// Hung up, was removed, or the conference ended.
  left,

  /// Did not answer, was busy, or could not be dialled. See
  /// [VobizConferenceParticipant.reason].
  failed;

  /// The server's value (`connecting`, `dialing`, `joined`, `on_hold`,
  /// `left`, `failed`). Anything else reads as [left].
  static VobizParticipantStatus parse(Object? value) => switch (value) {
        'connecting' => connecting,
        'dialing' => dialing,
        'joined' => joined,
        'on_hold' => onHold,
        'failed' => failed,
        _ => left,
      };
}

/// What [VobizConference.act] can do to one participant.
enum VobizParticipantAction {
  /// The others stop hearing them.
  mute,

  /// The others hear them again.
  unmute,

  /// Out of the room onto hold music: they hear nobody and nobody hears them.
  hold,

  /// Back into the room from hold.
  resume,

  /// Hang up their call.
  remove,
}

/// One person in a conference, as your server reports it.
@immutable
class VobizConferenceParticipant {
  const VobizConferenceParticipant({
    required this.id,
    required this.label,
    required this.status,
    this.isYou = false,
    this.role = '',
    this.muted = false,
    this.reason,
  });

  factory VobizConferenceParticipant.fromJson(Map<String, dynamic> json) => VobizConferenceParticipant(
        id: '${json['id'] ?? ''}',
        label: '${json['label'] ?? ''}',
        status: VobizParticipantStatus.parse(json['status']),
        isYou: json['you'] == true,
        role: '${json['role'] ?? ''}',
        muted: json['muted'] == true,
        reason: json['reason'] is String ? json['reason'] as String : null,
      );

  /// The server's id for this person. Pass it to [VobizConference.act].
  final String id;

  /// A phone number or SIP username.
  final String label;

  final VobizParticipantStatus status;

  /// This app's own leg. It is managed with the call's own controls (mute,
  /// hang up), not with [VobizConference.act].
  final bool isYou;

  /// `host` (this app), `guest` (the other side of the original call),
  /// `added` (dialled in) or `other`.
  final String role;

  final bool muted;

  /// Why someone [VobizParticipantStatus.failed] or left, when the server
  /// says: `busy`, `no answer`, `removed`, …
  final String? reason;

  /// Still in the conference: on the way in, being dialled, in the room or
  /// on hold.
  bool get isPresent => switch (status) {
        VobizParticipantStatus.connecting ||
        VobizParticipantStatus.dialing ||
        VobizParticipantStatus.joined ||
        VobizParticipantStatus.onHold =>
          true,
        VobizParticipantStatus.left || VobizParticipantStatus.failed => false,
      };
}

/// A conference as your server reports it.
@immutable
class VobizConferenceState {
  const VobizConferenceState({
    required this.room,
    required this.active,
    required this.participants,
    this.endedReason,
  });

  /// Reads the JSON every conference route answers with. Throws a
  /// [FormatException] when it is not one.
  factory VobizConferenceState.fromJson(Map<String, dynamic> json) {
    final room = json['room'];
    final list = json['participants'];
    if (room is! String || room.isEmpty || list is! List) {
      throw const FormatException('Not a conference state: needs "room" and "participants"');
    }
    return VobizConferenceState(
      room: room,
      active: json['active'] != false,
      participants: List<VobizConferenceParticipant>.unmodifiable(
          list.whereType<Map<String, dynamic>>().map(VobizConferenceParticipant.fromJson)),
      endedReason: json['ended_reason'] is String ? json['ended_reason'] as String : null,
    );
  }

  /// The Vobiz conference room's name.
  final String room;

  /// False once the conference has ended.
  final bool active;

  /// Everyone who has been in it, in the order they came, this app first.
  final List<VobizConferenceParticipant> participants;

  /// Why it ended, when it has.
  final String? endedReason;

  /// The people still in it (see [VobizConferenceParticipant.isPresent]),
  /// this app included.
  List<VobizConferenceParticipant> get present =>
      participants.where((p) => p.isPresent).toList(growable: false);
}

/// Turns the current call into a conference and manages the people in it,
/// through your server.
///
/// Vobiz mixes a conference in a room (VobizXML `<Conference>`). Moving a
/// call into a room, dialling people into it and muting them are Vobiz REST
/// calls that need the account's Auth Token, which must never ship in an
/// app. So this class asks your server, and your server makes those calls.
/// It implements four routes, each answering with the conference state (see
/// [VobizConferenceState.fromJson]):
///
/// | Route | JSON body |
/// |---|---|
/// | `POST /conference/add` | `call_uuid`, `number` or `user`, optional `caller_id` |
/// | `POST /conference/state` | `call_uuid` |
/// | `POST /conference/participant` | `call_uuid`, `participant_id`, `action` |
/// | `POST /conference/end` | `call_uuid` |
///
/// The first [add] moves both sides of the call into a room (Vobiz Transfer
/// API) and dials the new person into it (Call API); later ones only dial.
/// The example's sample server implements the routes
/// (example/push_bridge/README.md, "Conference"); a production app puts
/// them in its own backend.
///
/// ```dart
/// final conference = VobizConference(
///   client: client,
///   serverUrl: Uri.parse('https://api.example.com'),
///   headers: () async => {'Authorization': 'Bearer ${await session.token()}'},
/// );
/// await conference.add(number: '+919876543210', callerId: '+918000000000');
/// conference.state.addListener(() => print(conference.state.value?.present));
/// ```
///
/// While a conference is on, [state] is refreshed every [pollInterval]. It
/// goes back to null when the call ends.
///
/// When the conference ends (your server reports `active: false`, or [end]
/// returns), this class hangs up the call itself unless
/// [endCallWithConference] is false: the call's own leg was in the room and
/// is gone, and Vobiz's hang-up does not always reach the phone (a WebRTC
/// gateway was seen to drop a media server's BYE that came minutes after the
/// call's last SIP message).
class VobizConference {
  VobizConference({
    required this.client,
    required this.serverUrl,
    this.headers,
    this.callUuid,
    http.Client? httpClient,
    this.pollInterval = const Duration(seconds: 2),
    this.timeout = const Duration(seconds: 15),
    this.endCallWithConference = true,
  })  : _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null {
    _callEvents = client.callEvents.listen(_onCallEvent);
  }

  /// The client whose current call becomes the conference.
  final VobizClient client;

  /// Your server's base URL; the routes are appended to it.
  final Uri serverUrl;

  /// Headers for each request, typically your app's own `Authorization`.
  /// Called on every request, so it can return a freshly refreshed session.
  final FutureOr<Map<String, String>> Function()? headers;

  /// The CallUUID your server knows the current call by. Defaults to
  /// [VobizClient.callUuid], Vobiz's id for this app's own leg.
  final String? Function()? callUuid;

  /// How often [state] is refreshed while a conference is on.
  final Duration pollInterval;

  /// How long to wait for your server.
  final Duration timeout;

  /// Hang up the call when its conference ends. See the class description.
  final bool endCallWithConference;

  final http.Client _http;
  final bool _ownsHttp;
  late final StreamSubscription<CallEvent> _callEvents;
  final ValueNotifier<VobizConferenceState?> _state = ValueNotifier<VobizConferenceState?>(null);
  String? _uuid;
  Timer? _poll;
  bool _polling = false;
  bool _disposed = false;

  /// Counts calls that ended: a reply to a request sent before the call
  /// ended must not bring its conference back.
  int _generation = 0;

  /// The [_generation] whose call this class has already hung up.
  int _hungUpGeneration = -1;

  /// The current call's conference, or null when it is not one.
  ValueListenable<VobizConferenceState?> get state => _state;

  /// Dials [number] (E.164, e.g. `+919876543210`) or [sipUser] (a SIP
  /// endpoint username) into the conference. The first time, the call
  /// becomes the conference: both of its sides move into a new room.
  ///
  /// [callerId] is the number the dialled person sees; it must be one of
  /// your Vobiz numbers (E.164). Without it your server picks one.
  ///
  /// Throws [StateError] when there is no answered call, [ArgumentError]
  /// for a malformed target, and [VobizException]
  /// ([VobizErrorCode.conferenceFailed]) when your server refuses.
  Future<VobizConferenceState> add({String? number, String? sipUser, String? callerId}) async {
    if ((number == null) == (sipUser == null)) {
      throw ArgumentError('Pass either number or sipUser');
    }
    if (number != null && !e164Number.hasMatch(number)) {
      throw ArgumentError.value(number, 'number', 'must be E.164, e.g. +919876543210');
    }
    final user = sipUser == null ? null : VobizClient.endpointUsername(sipUser);
    if (user != null && !sipUserName.hasMatch(user)) {
      throw ArgumentError.value(sipUser, 'sipUser', 'must be a SIP endpoint username');
    }
    if (callerId != null && callerId.isNotEmpty && !e164Number.hasMatch(callerId)) {
      throw ArgumentError.value(callerId, 'callerId', 'must be E.164, e.g. +918000000000');
    }
    if (client.callState != CallStateStatus.active) {
      throw StateError('A conference starts from an answered call');
    }
    final uuid = _uuid ?? _currentCallUuid();
    if (uuid == null) throw StateError('Vobiz has not reported a CallUUID for this call yet');
    final generation = _generation;
    final state = await _send('/conference/add', <String, Object?>{
      'call_uuid': uuid,
      if (number != null) 'number': number,
      if (user != null) 'user': user,
      if (callerId != null && callerId.isNotEmpty) 'caller_id': callerId,
    });
    // The call ended (or this object was disposed) while the server answered:
    // its id must not come back for the next call.
    if (_isCurrent(generation)) {
      _uuid = uuid;
      _startPolling();
    }
    return state;
  }

  /// Mutes [participantId]: the others stop hearing them.
  Future<VobizConferenceState> mute(String participantId) => act(participantId, VobizParticipantAction.mute);

  /// Unmutes [participantId].
  Future<VobizConferenceState> unmute(String participantId) =>
      act(participantId, VobizParticipantAction.unmute);

  /// Puts [participantId] on hold music, out of the room.
  Future<VobizConferenceState> hold(String participantId) => act(participantId, VobizParticipantAction.hold);

  /// Brings [participantId] back into the room from hold.
  Future<VobizConferenceState> resume(String participantId) =>
      act(participantId, VobizParticipantAction.resume);

  /// Hangs up [participantId]'s call.
  Future<VobizConferenceState> remove(String participantId) =>
      act(participantId, VobizParticipantAction.remove);

  /// Does [action] to [participantId] (a [VobizConferenceParticipant.id]).
  Future<VobizConferenceState> act(String participantId, VobizParticipantAction action) => _send(
        '/conference/participant',
        <String, Object?>{'call_uuid': _requireConference(), 'participant_id': participantId, 'action': action.name},
      );

  /// Ends the conference for everyone, this app's call included.
  Future<VobizConferenceState> end() async {
    final uuid = _requireConference();
    final generation = _generation;
    final state = await _send('/conference/end', <String, Object?>{'call_uuid': uuid});
    // Only the call this conference was for: never a call that came after.
    if (_isCurrent(generation)) {
      _stopPolling();
      _hangUpEndedCall();
    }
    return state;
  }

  /// Asks your server for the conference now. Null when the current call is
  /// not a conference.
  ///
  /// A conference this object did not start (another [VobizConference] made
  /// the [add] for the same call) is taken over: its controls work and
  /// [state] is refreshed from then on.
  Future<VobizConferenceState?> refresh() async {
    final uuid = _uuid ?? _currentCallUuid();
    if (uuid == null) return null;
    final generation = _generation;
    final VobizConferenceState state;
    try {
      state = await _send('/conference/state', <String, Object?>{'call_uuid': uuid});
    } on VobizException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
    if (_uuid == null && state.active && _isCurrent(generation)) {
      _uuid = uuid;
      _startPolling();
    }
    return state;
  }

  /// Stops listening to the client and closes the HTTP client if this
  /// object created it.
  void dispose() {
    _disposed = true;
    _stopPolling();
    unawaited(_callEvents.cancel());
    _state.dispose();
    if (_ownsHttp) _http.close();
  }

  String? _currentCallUuid() {
    final uuid = (callUuid?.call() ?? client.callUuid)?.trim().toLowerCase();
    return uuid == null || uuid.isEmpty ? null : uuid;
  }

  String _requireConference() {
    final uuid = _uuid;
    if (uuid == null) throw StateError('The current call is not a conference');
    return uuid;
  }

  /// Whether the call a request was sent for ([generation]) is still the
  /// current one, and this object still in use.
  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _onCallEvent(CallEvent event) {
    if (event.state != CallStateStatus.ended && event.state != CallStateStatus.failed) return;
    // The app's leg has gone, and with it the conference it hosted.
    _generation++;
    _stopPolling();
    _uuid = null;
    if (!_disposed) _state.value = null;
  }

  void _startPolling() {
    _poll ??= Timer.periodic(pollInterval, (_) => unawaited(_pollOnce()));
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  Future<void> _pollOnce() async {
    if (_polling || _uuid == null) return;
    _polling = true;
    try {
      final state = await refresh();
      if (state == null || !state.active) _stopPolling();
    } catch (_) {
      // A missed refresh is retried at the next tick.
    } finally {
      _polling = false;
    }
  }

  Future<VobizConferenceState> _send(String route, Map<String, Object?> body) async {
    final generation = _generation;
    final extra = await headers?.call() ?? const <String, String>{};
    final base = serverUrl.toString().replaceAll(RegExp(r'/+$'), '');
    final http.Response response;
    try {
      response = await _http
          .post(
            Uri.parse('$base$route'),
            headers: <String, String>{...extra, 'Content-Type': 'application/json', 'Accept': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on TimeoutException catch (e) {
      throw VobizException(VobizErrorCode.conferenceFailed, 'Your conference server did not answer in time',
          cause: e);
    } catch (e) {
      throw VobizException(VobizErrorCode.conferenceFailed, 'Could not reach your conference server: $e', cause: e);
    }
    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      decoded = null;
    }
    final json = decoded is Map<String, dynamic> ? decoded : const <String, dynamic>{};
    if (response.statusCode >= 400) {
      // A refusal can still carry the current state (e.g. "not in the room").
      final current = json['conference'];
      if (current is Map<String, dynamic>) _publish(current, generation);
      final error = json['error'];
      throw VobizException(
        VobizErrorCode.conferenceFailed,
        error is String && error.isNotEmpty ? error : 'Your conference server answered HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    final state = _publish(json, generation);
    if (state == null) {
      throw const VobizException(VobizErrorCode.conferenceFailed, 'Your conference server did not answer with a conference');
    }
    return state;
  }

  /// Reads a state and shows it, unless the call it was for has ended.
  VobizConferenceState? _publish(Map<String, dynamic> json, int generation) {
    final VobizConferenceState state;
    try {
      state = VobizConferenceState.fromJson(json);
    } on FormatException {
      return null;
    }
    if (!_disposed && generation == _generation) {
      _state.value = state;
      if (!state.active) _hangUpEndedCall();
    }
    return state;
  }

  /// The room this call was in has ended: end the call too, rather than wait
  /// for a BYE that may not come.
  void _hangUpEndedCall() {
    if (!endCallWithConference || _disposed || _hungUpGeneration == _generation) return;
    final call = client.callState;
    if (call != CallStateStatus.active && call != CallStateStatus.held) return;
    _hungUpGeneration = _generation;
    unawaited(client.hangup().catchError((Object _) {}));
  }
}
