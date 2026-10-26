# Mobile voice input

Target release: v1.20.0.

Desktop-connected agent chat and Flowcy Agent use an iMessage-style composer:
a Liquid Glass capsule with the text field and one trailing button. That
button is a waveform icon with no background while the field is empty, and a
blue Send button once there is text. Mic and Send are the same size. Long-press
the waveform button to choose the recognition language without recording.

Tapping the waveform button replaces only the text field inside the capsule
with the recording content. The rest of the bar stays in place. The recording
content shows a pulsing red dot, the elapsed time, a live red waveform, the
current language code (tap it to change language), and a red Stop button. An
✕ button slides in beside the capsule to discard the recording and restore the
earlier draft. Recording and the timer pause while the language sheet is open,
then resume in the selected language. The language preference is remembered on
the device.

Stop moves to review. The capsule shows the recorded waveform, which animates
in, with the duration and a blue Send button. The transcribed text appears
under the waveform. Send delivers the text through the normal chat transport.
Tapping the text returns it to the text field for editing. Sending stays
unavailable while the agent cannot accept a message. The capsule changes state
with spring and blur transitions, and haptics confirm each action.

The implementation uses Apple's Speech framework and AVAudioEngine. It checks
`supportsOnDeviceRecognition` and sets `requiresOnDeviceRecognition` before
capturing audio. An unsupported language produces an alert; there is no server
recognition fallback. Audio buffers are not saved or attached to chat messages.
The waveform displays microphone RMS levels, with reduced animation when Reduce
Motion is enabled.

During recording, the microphone becomes **Send Voice Message** and the original
Send button is hidden. Transcription updates the draft while the recording
capsule occupies the text field's space. Tapping the replacement Send button stops capture, allows up to
three seconds for final results, then sends through the normal chat transport.
The Send button remains directly tappable beside the recording capsule. Stop
ends recording and restores the text field with the editable draft without
sending. Sending stays unavailable while the agent cannot accept a message.

Microphone capture stops when the recording ends, the app enters the background,
the audio session is interrupted, or an input device disconnects. After an
interruption, the partial text opens in review. Late permission responses and
recognition callbacks cannot restart a canceled recording.

## Verification

`MobileSpeechRecognizerTests` covers denied speech/microphone permissions and
late permission responses after cancellation or interruption. The iPhone UI plan
uses a DEBUG-only simulator recording fixture to check the inline capsule, language
sheet, Stop → review with the transcript, editing the transcript in the text
field, and sending from review. It does not exercise Apple's recognizer.

Before release, verify on a physical iPhone and iPad:

- Grant speech and microphone access; dictate in two supported languages and
  confirm the waveform responds to sound, including in airplane mode with the
  required language assets already installed.
- Stop right after the last word and check the review transcript includes it.
- Edit the transcript from review, and discard with ✕. Open language settings
  during recording and confirm capture and the timer pause and resume correctly.
- Deny each permission separately and verify the native alert and Settings link.
- Select a language without on-device support and verify capture does not start.
- Background the app, interrupt audio with a call, disconnect the microphone,
  and cancel while permissions are pending. Confirm capture stops and existing
  text remains available.
- Check VoiceOver, large Dynamic Type, Reduce Motion, and iPad sheet layouts.

Simulator tests do not establish physical microphone behavior, transcription
accuracy, installed-language availability, or offline recognition on a device.
