#import "PetRTCDevice.h"
#import "PetRTCAudioDeviceProtocol.h"

// The macOS binary exports the injectable audio module. Its public protocol
// header is shipped in the iOS slice of the same WebRTC framework.
@interface PetRTCDevice () <RTCAudioDevice>
@property (atomic, strong) id<RTCAudioDeviceDelegate> audioDelegate;
@property (atomic) BOOL isPlaying;
@property (atomic) BOOL isRecording;
@end

@implementation PetRTCDevice
- (RTCPeerConnectionFactory *)makeFactory {
    return [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:nil decoderFactory:nil audioDevice:self];
}
- (double)deviceInputSampleRate { return 24000; }
- (double)deviceOutputSampleRate { return 24000; }
- (NSInteger)inputNumberOfChannels { return 1; }
- (NSInteger)outputNumberOfChannels { return 1; }
- (double)inputIOBufferDuration { return 0.01; }
- (double)outputIOBufferDuration { return 0.01; }
- (double)inputLatency { return 0; }
- (double)outputLatency { return 0; }
- (BOOL)isInitialized { return self.audioDelegate != nil; }
- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate {
    self.audioDelegate = delegate;
    return YES;
}
- (BOOL)terminateDevice {
    self.isPlaying = NO;
    self.isRecording = NO;
    self.audioDelegate = nil;
    return YES;
}
- (BOOL)isPlayoutInitialized { return YES; }
- (BOOL)isRecordingInitialized { return YES; }
- (BOOL)initializePlayout { return YES; }
- (BOOL)initializeRecording { return YES; }
- (BOOL)startPlayout { self.isPlaying = YES; return YES; }
- (BOOL)stopPlayout { self.isPlaying = NO; return YES; }
- (BOOL)startRecording { self.isRecording = YES; return YES; }
- (BOOL)stopRecording { self.isRecording = NO; return YES; }

- (void)hardwareWillStart {
    id<RTCAudioDeviceDelegate> delegate = self.audioDelegate;
    [delegate dispatchSync:^{
        [delegate notifyAudioInputInterrupted];
        [delegate notifyAudioOutputInterrupted];
    }];
}

- (void)recordPCM:(NSData *)pcm {
    id<RTCAudioDeviceDelegate> delegate = self.audioDelegate;
    if (!delegate || !self.isRecording || !self.captureEnabled) return;
    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp timestamp = {.mHostTime = AudioGetCurrentHostTime(), .mFlags = kAudioTimeStampHostTimeValid};
    AudioBufferList list = {1, {{1, (UInt32)pcm.length, (void *)pcm.bytes}}};
    delegate.deliverRecordedData(&flags, &timestamp, 1, (UInt32)pcm.length / 2, &list, NULL, nil);
}

- (AVAudioSourceNode *)makeSource {
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                            sampleRate:24000 channels:1 interleaved:YES];
    return [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:
        ^OSStatus(BOOL *silence, const AudioTimeStamp *time, AVAudioFrameCount count, AudioBufferList *data) {
            id<RTCAudioDeviceDelegate> delegate = self.audioDelegate;
            if (!delegate || !self.isPlaying) {
                *silence = YES;
                memset(data->mBuffers[0].mData, 0, data->mBuffers[0].mDataByteSize);
                return noErr;
            }
            AudioUnitRenderActionFlags flags = 0;
            OSStatus status = delegate.getPlayoutData(&flags, time, 0, count, data);
            // Keep draining WebRTC so unmuting resumes at the current sample.
            if (self.outputMuted) {
                *silence = YES;
                memset(data->mBuffers[0].mData, 0, data->mBuffers[0].mDataByteSize);
            }
            return status;
        }];
}
@end
