import Testing

/// P38 C: dictation and live voice intentionally share one active microphone owner.
/// Serialize both suites together so fixtures cannot cancel another suite's session.
@Suite(.serialized) struct VoiceSessionTests {}
