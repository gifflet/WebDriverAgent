/**
 * FBAudioBroadcastPickerViewController
 *
 * Full-screen view controller IntegrationApp swaps in when launched with
 * `-gads-audio-picker`. Shows an `RPSystemBroadcastPickerView` configured
 * for the WebDriverAgentBroadcast extension and a hint label so the user
 * knows what to do (PRD §D4 — paridade with Android Allow dialog).
 */

#import <UIKit/UIKit.h>

@class RPSystemBroadcastPickerView;

NS_ASSUME_NONNULL_BEGIN

extern NSString *const FBAudioBroadcastPickerLaunchArgument;
extern NSString *const FBAudioBroadcastExtensionBundleIdentifier;

@interface FBAudioBroadcastPickerViewController : UIViewController
@property (nonatomic, strong) RPSystemBroadcastPickerView *picker;
@end

NS_ASSUME_NONNULL_END
