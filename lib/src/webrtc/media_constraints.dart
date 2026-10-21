class MediaConstraints {
  const MediaConstraints({
    this.audio = true,
    this.video = false,
    this.echoCancellation = true,
    this.noiseSuppression = true,
    this.autoGainControl = true,
    this.preferredAudioCodecs = const <String>[],
  });

  final bool audio;
  final bool video;
  final bool echoCancellation;
  final bool noiseSuppression;
  final bool autoGainControl;

  /// Audio codecs to list first in the SDK's offers and answers, by encoding
  /// name, such as `['opus']`. Empty (the default) keeps WebRTC's own order,
  /// which already lists Opus first. The media server makes the final choice:
  /// Vobiz currently answers WebRTC calls with PCMU.
  final List<String> preferredAudioCodecs;

  Map<String, dynamic> toWebRtcConstraints() => <String, dynamic>{
        'audio': audio
            ? <String, dynamic>{
                'echoCancellation': echoCancellation,
                'noiseSuppression': noiseSuppression,
                'autoGainControl': autoGainControl,
              }
            : false,
        'video': video,
      };
}
