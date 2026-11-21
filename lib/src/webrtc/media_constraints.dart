class MediaConstraints {
  const MediaConstraints({
    @Deprecated('Ignored: a call always opens the microphone') this.audio = true,
    @Deprecated('Ignored: the SDK is audio-only and never opens the camera') this.video = false,
    this.echoCancellation = true,
    this.noiseSuppression = true,
    this.autoGainControl = true,
    this.preferredAudioCodecs = const <String>[],
  });

  /// Ignored: a call always opens the microphone, since it has nothing else
  /// to send.
  @Deprecated('Ignored: a call always opens the microphone')
  final bool audio;

  /// Ignored: the SDK is audio-only. Opening the camera would only ask for
  /// the camera permission and keep the camera on while nothing is sent.
  @Deprecated('Ignored: the SDK is audio-only and never opens the camera')
  final bool video;

  final bool echoCancellation;
  final bool noiseSuppression;
  final bool autoGainControl;

  /// Audio codecs to list first in the SDK's offers and answers, by encoding
  /// name, such as `['opus']`. Empty (the default) keeps WebRTC's own order,
  /// which already lists Opus first. The media server makes the final choice:
  /// Vobiz currently answers WebRTC calls with PCMU.
  final List<String> preferredAudioCodecs;

  /// The `getUserMedia` constraints: the microphone, never the camera. The
  /// processing flags are given in the W3C form (the web) and in the
  /// `optional` form flutter_webrtc reads on Android and iOS, which ignore
  /// the W3C keys and, given a map, drop their own defaults.
  Map<String, dynamic> toWebRtcConstraints() => <String, dynamic>{
        'audio': <String, dynamic>{
          'echoCancellation': echoCancellation,
          'noiseSuppression': noiseSuppression,
          'autoGainControl': autoGainControl,
          'optional': <Map<String, String>>[
            <String, String>{'googEchoCancellation': '$echoCancellation'},
            <String, String>{'echoCancellation': '$echoCancellation'},
            <String, String>{'googEchoCancellation2': '$echoCancellation'},
            <String, String>{'googDAEchoCancellation': '$echoCancellation'},
            <String, String>{'googNoiseSuppression': '$noiseSuppression'},
            <String, String>{'googAutoGainControl': '$autoGainControl'},
          ],
        },
        'video': false,
      };
}
