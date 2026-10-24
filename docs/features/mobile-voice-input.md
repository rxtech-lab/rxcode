# Mobile voice input

Target release: v1.20.0.

Desktop-connected agent chat and Flowcy Agent expose a microphone button beside
the composer. The button opens a dedicated sheet; recording starts only after
the user taps **Start Recording**. The recognition language is selected on a
separate searchable screen and remembered on the device.

The implementation uses Apple's Speech framework and AVAudioEngine. It checks
`supportsOnDeviceRecognition` and sets `requiresOnDeviceRecognition` before
capturing audio. An unsupported language produces an alert; there is no server
recognition fallback. Audio buffers are not saved or attached to chat messages.
The waveform displays microphone RMS levels, with reduced animation when Reduce
Motion is enabled.

**Stop Recording** ends capture and allows up to three seconds for final results.
The user can edit the transcript or record another segment. **Add to Message**
appends the transcript to the existing composer draft without sending it. Sending
the message uses the normal chat transport and selected agent. Canceling a
nonempty transcript requires native discard confirmation.

Microphone capture stops when the sheet closes, the app enters the background,
the audio session is interrupted, or an input device disconnects. Partial text
remains available for review after interruptions. Late permission responses and
recognition callbacks cannot restart a canceled recording.

## Verification

`MobileSpeechRecognizerTests` covers denied speech/microphone permissions and
late permission responses after cancellation or interruption. The iPhone UI plan
includes voice-sheet entry from both composers, recognition-language navigation
and persistence, and preservation of an existing draft when canceling.

Before release, verify on a physical iPhone and iPad:

- Grant speech and microphone access; dictate in two supported languages and
  confirm the waveform responds to sound, including in airplane mode with the
  required language assets already installed.
- Stop after the last word, review and edit the result, record another segment,
  and add it to an existing draft. Confirm no message sends before tapping Send.
- Deny each permission separately and verify the native alert and Settings link.
- Select a language without on-device support and verify capture does not start.
- Background the app, interrupt audio with a call, disconnect the microphone,
  and cancel while permissions are pending. Confirm capture stops and existing
  text remains available.
- Check VoiceOver, large Dynamic Type, Reduce Motion, and iPad sheet layouts.

Simulator tests do not establish physical microphone behavior, transcription
accuracy, installed-language availability, or offline recognition on a device.
