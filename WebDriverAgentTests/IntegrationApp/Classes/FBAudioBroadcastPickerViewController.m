#import "FBAudioBroadcastPickerViewController.h"
#import <ReplayKit/ReplayKit.h>
#import <objc/message.h>

NSString *const FBAudioBroadcastPickerLaunchArgument = @"-gads-audio-picker";
NSString *const FBAudioBroadcastExtensionBundleIdentifier = @"br.com.zeevo.WebDriverAgentBroadcast";

@implementation FBAudioBroadcastPickerViewController

- (void)viewDidLoad
{
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.systemBackgroundColor;

  UILabel *hint = [[UILabel alloc] init];
  hint.translatesAutoresizingMaskIntoConstraints = NO;
  hint.numberOfLines = 0;
  hint.textAlignment = NSTextAlignmentCenter;
  hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  hint.text = @"Starting GADS audio broadcast. If the system prompt appears, accept it.";
  [self.view addSubview:hint];

  // Off-screen / minimal-size picker: we don't want the user to tap it manually,
  // we trigger it programmatically right after viewDidAppear (see below).
  self.picker = [[RPSystemBroadcastPickerView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
  self.picker.translatesAutoresizingMaskIntoConstraints = NO;
  self.picker.preferredExtension = FBAudioBroadcastExtensionBundleIdentifier;
  self.picker.showsMicrophoneButton = NO;
  [self.view addSubview:self.picker];

  UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [hint.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
    [hint.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
    [hint.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],

    [self.picker.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
    [self.picker.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:24],
    [self.picker.widthAnchor constraintEqualToConstant:1],
    [self.picker.heightAnchor constraintEqualToConstant:1],
  ]];
}

- (void)viewDidAppear:(BOOL)animated
{
  [super viewDidAppear:animated];
  // Programmatically start the broadcast — same trick used by Zoom/Twilio/Vonage.
  // `buttonPressed:` is a private RPSystemBroadcastPickerView selector that
  // triggers the broadcast as if the user had tapped the button. Falls back to
  // sending UIControlEventTouchUpInside on the inner UIButton if Apple ever
  // renames or removes the selector.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    SEL pressed = NSSelectorFromString(@"buttonPressed:");
    if ([self.picker respondsToSelector:pressed]) {
      ((void (*)(id, SEL, id))objc_msgSend)(self.picker, pressed, nil);
      return;
    }
    for (UIView *sub in self.picker.subviews) {
      if ([sub isKindOfClass:UIButton.class]) {
        [(UIButton *)sub sendActionsForControlEvents:UIControlEventTouchUpInside];
        return;
      }
    }
  });
}

@end
