#import <AVFoundation/AVFoundation.h>
#import <WebRTC/RTCPeerConnectionFactory.h>

NS_ASSUME_NONNULL_BEGIN
NS_SWIFT_SENDABLE
@interface PetRTCDevice : NSObject
- (RTCPeerConnectionFactory *)makeFactory;
- (AVAudioSourceNode *)makeSource;
- (void)recordPCM:(NSData *)pcm;
- (void)hardwareWillStart;
@end
NS_ASSUME_NONNULL_END
