// Copyright 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#define FML_USED_ON_EMBEDDER

#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterViewController_Internal.h"

#include <memory>

#include "flutter/fml/message_loop.h"
#include "flutter/fml/platform/darwin/platform_version.h"
#include "flutter/fml/platform/darwin/scoped_nsobject.h"
#include "flutter/shell/common/thread_host.h"
#include "flutter/shell/platform/darwin/ios/framework/Source/FlutterDartProject_Internal.h"
#include "flutter/shell/platform/darwin/ios/framework/Source/FlutterPlatformPlugin.h"
#include "flutter/shell/platform/darwin/ios/framework/Source/FlutterTextInputDelegate.h"
#include "flutter/shell/platform/darwin/ios/framework/Source/FlutterTextInputPlugin.h"
#include "flutter/shell/platform/darwin/ios/framework/Source/FlutterView.h"
#include "flutter/shell/platform/darwin/ios/framework/Source/flutter_touch_mapper.h"
#include "flutter/shell/platform/darwin/ios/framework/Source/platform_message_response_darwin.h"
#include "flutter/shell/platform/darwin/ios/platform_view_ios.h"

@interface FlutterViewController () <FlutterTextInputDelegate>
@property(nonatomic, readonly) NSMutableDictionary* pluginPublications;
@end

@interface FlutterViewControllerRegistrar : NSObject <FlutterPluginRegistrar>
- (instancetype)initWithPlugin:(NSString*)pluginKey
         flutterViewController:(FlutterViewController*)flutterViewController;
@end

@implementation FlutterViewController {
  fml::scoped_nsobject<FlutterDartProject> _dartProject;
  shell::ThreadHost _threadHost;
  std::unique_ptr<shell::Shell> _shell;

  // Channels
  fml::scoped_nsobject<FlutterPlatformPlugin> _platformPlugin;
  fml::scoped_nsobject<FlutterTextInputPlugin> _textInputPlugin;
  fml::scoped_nsobject<FlutterMethodChannel> _localizationChannel;
  fml::scoped_nsobject<FlutterMethodChannel> _navigationChannel;
  fml::scoped_nsobject<FlutterMethodChannel> _platformChannel;
  fml::scoped_nsobject<FlutterMethodChannel> _textInputChannel;
  fml::scoped_nsobject<FlutterBasicMessageChannel> _lifecycleChannel;
  fml::scoped_nsobject<FlutterBasicMessageChannel> _systemChannel;
  fml::scoped_nsobject<FlutterBasicMessageChannel> _settingsChannel;

  // We keep a separate reference to this and create it ahead of time because we want to be able to
  // setup a shell along with its platform view before the view has to appear.
  fml::scoped_nsobject<FlutterView> _flutterView;
  fml::scoped_nsobject<UIView> _launchView;
  UIInterfaceOrientationMask _orientationPreferences;
  UIStatusBarStyle _statusBarStyle;
  blink::ViewportMetrics _viewportMetrics;
  shell::TouchMapper _touchMapper;
  int64_t _nextTextureId;
  BOOL _initialized;
}

#pragma mark - Manage and override all designated initializers

- (instancetype)initWithProject:(FlutterDartProject*)project
                        nibName:(NSString*)nibNameOrNil
                         bundle:(NSBundle*)nibBundleOrNil {
  self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];

  if (self) {
    if (project == nil)
      _dartProject.reset([[FlutterDartProject alloc] initFromDefaultSourceForConfiguration]);
    else
      _dartProject.reset([project retain]);

    [self performCommonViewControllerInitialization];
  }

  return self;
}

- (instancetype)initWithNibName:(NSString*)nibNameOrNil bundle:(NSBundle*)nibBundleOrNil {
  return [self initWithProject:nil nibName:nil bundle:nil];
}

- (instancetype)initWithCoder:(NSCoder*)aDecoder {
  return [self initWithProject:nil nibName:nil bundle:nil];
}

#pragma mark - Common view controller initialization tasks

- (void)performCommonViewControllerInitialization {
  if (_initialized)
    return;

  _initialized = YES;

  _orientationPreferences = UIInterfaceOrientationMaskAll;
  _statusBarStyle = UIStatusBarStyleDefault;

  if ([self setupShell]) {
    [self setupChannels];
    [self setupNotificationCenterObservers];

    _pluginPublications = [NSMutableDictionary new];
  }
}

- (shell::Shell&)shell {
  FXL_DCHECK(_shell);
  return *_shell;
}

- (fml::WeakPtr<shell::PlatformViewIOS>)iosPlatformView {
  FXL_DCHECK(_shell);
  return _shell->GetPlatformView();
}

- (BOOL)setupShell {
  FXL_DCHECK(_shell == nullptr);

  static size_t shell_count = 1;

  auto threadLabel = [NSString stringWithFormat:@"io.flutter.%zu", shell_count++];

  _threadHost = {
      threadLabel.UTF8String,  // label
      shell::ThreadHost::Type::UI | shell::ThreadHost::Type::GPU | shell::ThreadHost::Type::IO};

  // The current thread will be used as the platform thread. Ensure that the message loop is
  // initialized.
  fml::MessageLoop::EnsureInitializedForCurrentThread();

  blink::TaskRunners task_runners(threadLabel.UTF8String,                          // label
                                  fml::MessageLoop::GetCurrent().GetTaskRunner(),  // platform
                                  _threadHost.gpu_thread->GetTaskRunner(),         // gpu
                                  _threadHost.ui_thread->GetTaskRunner(),          // ui
                                  _threadHost.io_thread->GetTaskRunner()           // io
  );

  _flutterView.reset([[FlutterView alloc] init]);

  // Lambda captures by pointers to ObjC objects are fine here because the create call is
  // synchronous.
  shell::Shell::CreateCallback<shell::PlatformView> on_create_platform_view =
      [flutter_view_controller = self, flutter_view = _flutterView.get()](shell::Shell& shell) {
        auto platform_view_ios = std::make_unique<shell::PlatformViewIOS>(
            shell,                    // delegate
            shell.GetTaskRunners(),   // task runners
            flutter_view_controller,  // flutter view controller owner
            flutter_view              // flutter view owner
        );
        return platform_view_ios;
      };

  shell::Shell::CreateCallback<shell::Rasterizer> on_create_rasterizer = [](shell::Shell& shell) {
    return std::make_unique<shell::Rasterizer>(shell.GetTaskRunners());
  };

  // Create the shell.
  _shell = shell::Shell::Create(std::move(task_runners),  //
                                [_dartProject settings],  //
                                on_create_platform_view,  //
                                on_create_rasterizer      //
  );

  if (!_shell) {
    FXL_LOG(ERROR) << "Could not setup a shell to run the Dart application.";
    return false;
  }

  return true;
}

- (void)setupChannels {
  _localizationChannel.reset([[FlutterMethodChannel alloc]
         initWithName:@"flutter/localization"
      binaryMessenger:self
                codec:[FlutterJSONMethodCodec sharedInstance]]);

  _navigationChannel.reset([[FlutterMethodChannel alloc]
         initWithName:@"flutter/navigation"
      binaryMessenger:self
                codec:[FlutterJSONMethodCodec sharedInstance]]);

  _platformChannel.reset([[FlutterMethodChannel alloc]
         initWithName:@"flutter/platform"
      binaryMessenger:self
                codec:[FlutterJSONMethodCodec sharedInstance]]);

  _textInputChannel.reset([[FlutterMethodChannel alloc]
         initWithName:@"flutter/textinput"
      binaryMessenger:self
                codec:[FlutterJSONMethodCodec sharedInstance]]);

  _lifecycleChannel.reset([[FlutterBasicMessageChannel alloc]
         initWithName:@"flutter/lifecycle"
      binaryMessenger:self
                codec:[FlutterStringCodec sharedInstance]]);

  _systemChannel.reset([[FlutterBasicMessageChannel alloc]
         initWithName:@"flutter/system"
      binaryMessenger:self
                codec:[FlutterJSONMessageCodec sharedInstance]]);

  _settingsChannel.reset([[FlutterBasicMessageChannel alloc]
         initWithName:@"flutter/settings"
      binaryMessenger:self
                codec:[FlutterJSONMessageCodec sharedInstance]]);

  _platformPlugin.reset([[FlutterPlatformPlugin alloc] init]);
  [_platformChannel.get() setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
    [_platformPlugin.get() handleMethodCall:call result:result];
  }];

  _textInputPlugin.reset([[FlutterTextInputPlugin alloc] init]);
  _textInputPlugin.get().textInputDelegate = self;
  [_textInputChannel.get() setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
    [_textInputPlugin.get() handleMethodCall:call result:result];
  }];
  static_cast<shell::PlatformViewIOS*>(_shell->GetPlatformView().get())
      ->SetTextInputPlugin(_textInputPlugin);
}

- (void)setupNotificationCenterObservers {
  NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
  [center addObserver:self
             selector:@selector(onOrientationPreferencesUpdated:)
                 name:@(shell::kOrientationUpdateNotificationName)
               object:nil];

  [center addObserver:self
             selector:@selector(onPreferredStatusBarStyleUpdated:)
                 name:@(shell::kOverlayStyleUpdateNotificationName)
               object:nil];

  [center addObserver:self
             selector:@selector(applicationBecameActive:)
                 name:UIApplicationDidBecomeActiveNotification
               object:nil];

  [center addObserver:self
             selector:@selector(applicationWillResignActive:)
                 name:UIApplicationWillResignActiveNotification
               object:nil];

  [center addObserver:self
             selector:@selector(applicationDidEnterBackground:)
                 name:UIApplicationDidEnterBackgroundNotification
               object:nil];

  [center addObserver:self
             selector:@selector(applicationWillEnterForeground:)
                 name:UIApplicationWillEnterForegroundNotification
               object:nil];

  [center addObserver:self
             selector:@selector(keyboardWillChangeFrame:)
                 name:UIKeyboardWillChangeFrameNotification
               object:nil];

  [center addObserver:self
             selector:@selector(keyboardWillBeHidden:)
                 name:UIKeyboardWillHideNotification
               object:nil];

  [center addObserver:self
             selector:@selector(onLocaleUpdated:)
                 name:NSCurrentLocaleDidChangeNotification
               object:nil];

  [center addObserver:self
             selector:@selector(onAccessibilityStatusChanged:)
                 name:UIAccessibilityVoiceOverStatusChanged
               object:nil];

  [center addObserver:self
             selector:@selector(onAccessibilityStatusChanged:)
                 name:UIAccessibilitySwitchControlStatusDidChangeNotification
               object:nil];

  [center addObserver:self
             selector:@selector(onAccessibilityStatusChanged:)
                 name:UIAccessibilitySpeakScreenStatusDidChangeNotification
               object:nil];

  [center addObserver:self
             selector:@selector(onMemoryWarning:)
                 name:UIApplicationDidReceiveMemoryWarningNotification
               object:nil];

  [center addObserver:self
             selector:@selector(onUserSettingsChanged:)
                 name:UIContentSizeCategoryDidChangeNotification
               object:nil];
}

- (void)setInitialRoute:(NSString*)route {
  [_navigationChannel.get() invokeMethod:@"setInitialRoute" arguments:route];
}

#pragma mark - Loading the view

- (void)loadView {
  self.view = _flutterView.get();
  self.view.multipleTouchEnabled = YES;
  self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

  [self installLaunchViewIfNecessary];
}

#pragma mark - Managing launch views

- (void)installLaunchViewIfNecessary {
  // Show the launch screen view again on top of the FlutterView if available.
  // This launch screen view will be removed once the first Flutter frame is rendered.
  [_launchView.get() removeFromSuperview];
  _launchView.reset();
  NSString* launchStoryboardName =
      [[[NSBundle mainBundle] infoDictionary] objectForKey:@"UILaunchStoryboardName"];
  if (launchStoryboardName && !self.isBeingPresented && !self.isMovingToParentViewController) {
    UIViewController* launchViewController =
        [[UIStoryboard storyboardWithName:launchStoryboardName bundle:nil]
            instantiateInitialViewController];
    _launchView.reset([launchViewController.view retain]);
    _launchView.get().frame = self.view.bounds;
    _launchView.get().autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_launchView.get()];
  }
}

- (void)removeLaunchViewIfPresent {
  if (!_launchView) {
    return;
  }

  [UIView animateWithDuration:0.2
      animations:^{
        _launchView.get().alpha = 0;
      }
      completion:^(BOOL finished) {
        [_launchView.get() removeFromSuperview];
        _launchView.reset();
      }];
}

- (void)installLaunchViewCallback {
  if (!_shell || !_launchView) {
    return;
  }
  auto weak_platform_view = _shell->GetPlatformView();
  if (!weak_platform_view) {
    return;
  }
  __unsafe_unretained auto weak_flutter_view_controller = self;
  // This is on the platform thread.
  weak_platform_view->SetNextFrameCallback(
      [weak_platform_view, weak_flutter_view_controller,
       task_runner = _shell->GetTaskRunners().GetPlatformTaskRunner()]() {
        // This is on the GPU thread.
        task_runner->PostTask([weak_platform_view, weak_flutter_view_controller]() {
          // We check if the weak platform view is alive. If it is alive, then the view controller
          // also has to be alive since the view controller owns the platform view via the shell
          // association. Thus, we are not convinced that the unsafe unretained weak object is in
          // fact alive.
          if (weak_platform_view) {
            [weak_flutter_view_controller removeLaunchViewIfPresent];
          }
        });
      });
}

#pragma mark - Surface creation and teardown updates

- (void)surfaceUpdated:(BOOL)appeared {
  // NotifyCreated/NotifyDestroyed are synchronous and require hops between the UI and GPU thread.
  if (appeared) {
    [self installLaunchViewCallback];
    _shell->GetPlatformView()->NotifyCreated();

  } else {
    _shell->GetPlatformView()->NotifyDestroyed();
  }
}

#pragma mark - UIViewController lifecycle notifications

- (void)viewWillAppear:(BOOL)animated {
  TRACE_EVENT0("flutter", "viewWillAppear");

  // Launch the Dart application with the inferred run configuration.
  _shell->GetTaskRunners().GetUITaskRunner()->PostTask(
      fxl::MakeCopyable([engine = _shell->GetEngine(),                   //
                         config = [_dartProject.get() runConfiguration]  //
  ]() mutable {
        if (engine) {
          auto result = engine->Run(std::move(config));
          if (!result) {
            FXL_LOG(ERROR) << "Could not launch engine with configuration.";
          }
        }
      }));

  // Only recreate surface on subsequent appearances when viewport metrics are known.
  // First time surface creation is done on viewDidLayoutSubviews.
  if (_viewportMetrics.physical_width)
    [self surfaceUpdated:YES];
  [_lifecycleChannel.get() sendMessage:@"AppLifecycleState.inactive"];

  [super viewWillAppear:animated];
}

- (void)viewDidAppear:(BOOL)animated {
  TRACE_EVENT0("flutter", "viewDidAppear");
  [self onLocaleUpdated:nil];
  [self onUserSettingsChanged:nil];
  [self onAccessibilityStatusChanged:nil];
  [_lifecycleChannel.get() sendMessage:@"AppLifecycleState.resumed"];

  [super viewDidAppear:animated];
}

- (void)viewWillDisappear:(BOOL)animated {
  TRACE_EVENT0("flutter", "viewWillDisappear");
  [_lifecycleChannel.get() sendMessage:@"AppLifecycleState.inactive"];

  [super viewWillDisappear:animated];
}

- (void)viewDidDisappear:(BOOL)animated {
  TRACE_EVENT0("flutter", "viewDidDisappear");
  [self surfaceUpdated:NO];
  [_lifecycleChannel.get() sendMessage:@"AppLifecycleState.paused"];

  [super viewDidDisappear:animated];
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [_pluginPublications release];
  [super dealloc];
}

#pragma mark - Application lifecycle notifications

- (void)applicationBecameActive:(NSNotification*)notification {
  TRACE_EVENT0("flutter", "applicationBecameActive");
  [_lifecycleChannel.get() sendMessage:@"AppLifecycleState.resumed"];
}

- (void)applicationWillResignActive:(NSNotification*)notification {
  TRACE_EVENT0("flutter", "applicationWillResignActive");
  [_lifecycleChannel.get() sendMessage:@"AppLifecycleState.inactive"];
}

- (void)applicationDidEnterBackground:(NSNotification*)notification {
  TRACE_EVENT0("flutter", "applicationDidEnterBackground");
  [self surfaceUpdated:NO];
  [_lifecycleChannel.get() sendMessage:@"AppLifecycleState.paused"];
}

- (void)applicationWillEnterForeground:(NSNotification*)notification {
  TRACE_EVENT0("flutter", "applicationWillEnterForeground");
  if (_viewportMetrics.physical_width)
    [self surfaceUpdated:YES];
  [_lifecycleChannel.get() sendMessage:@"AppLifecycleState.inactive"];
}

#pragma mark - Touch event handling

enum MapperPhase {
  Accessed,
  Added,
  Removed,
};

using PointerChangeMapperPhase = std::pair<blink::PointerData::Change, MapperPhase>;
static inline PointerChangeMapperPhase PointerChangePhaseFromUITouchPhase(UITouchPhase phase) {
  switch (phase) {
    case UITouchPhaseBegan:
      return PointerChangeMapperPhase(blink::PointerData::Change::kDown, MapperPhase::Added);
    case UITouchPhaseMoved:
    case UITouchPhaseStationary:
      // There is no EVENT_TYPE_POINTER_STATIONARY. So we just pass a move type
      // with the same coordinates
      return PointerChangeMapperPhase(blink::PointerData::Change::kMove, MapperPhase::Accessed);
    case UITouchPhaseEnded:
      return PointerChangeMapperPhase(blink::PointerData::Change::kUp, MapperPhase::Removed);
    case UITouchPhaseCancelled:
      return PointerChangeMapperPhase(blink::PointerData::Change::kCancel, MapperPhase::Removed);
  }

  return PointerChangeMapperPhase(blink::PointerData::Change::kCancel, MapperPhase::Accessed);
}

static inline blink::PointerData::DeviceKind DeviceKindFromTouchType(UITouch* touch) {
  if (@available(iOS 9, *)) {
    switch (touch.type) {
      case UITouchTypeDirect:
      case UITouchTypeIndirect:
        return blink::PointerData::DeviceKind::kTouch;
      case UITouchTypeStylus:
        return blink::PointerData::DeviceKind::kStylus;
    }
  } else {
    return blink::PointerData::DeviceKind::kTouch;
  }

  return blink::PointerData::DeviceKind::kTouch;
}

- (void)dispatchTouches:(NSSet*)touches phase:(UITouchPhase)phase {
  // Note: we cannot rely on touch.phase, since in some cases, e.g.,
  // handleStatusBarTouches, we synthesize touches from existing events.
  //
  // TODO(cbracken) consider creating out own class with the touch fields we
  // need.
  auto eventTypePhase = PointerChangePhaseFromUITouchPhase(phase);
  const CGFloat scale = [UIScreen mainScreen].scale;
  auto packet = std::make_unique<blink::PointerDataPacket>(touches.count);

  int i = 0;
  for (UITouch* touch in touches) {
    int device_id = 0;

    switch (eventTypePhase.second) {
      case Accessed:
        device_id = _touchMapper.identifierOf(touch);
        break;
      case Added:
        device_id = _touchMapper.registerTouch(touch);
        break;
      case Removed:
        device_id = _touchMapper.unregisterTouch(touch);
        break;
    }

    FXL_DCHECK(device_id != 0);
    CGPoint windowCoordinates = [touch locationInView:self.view];

    blink::PointerData pointer_data;
    pointer_data.Clear();

    constexpr int kMicrosecondsPerSecond = 1000 * 1000;
    pointer_data.time_stamp = touch.timestamp * kMicrosecondsPerSecond;

    pointer_data.change = eventTypePhase.first;

    pointer_data.kind = DeviceKindFromTouchType(touch);

    pointer_data.device = device_id;

    pointer_data.physical_x = windowCoordinates.x * scale;
    pointer_data.physical_y = windowCoordinates.y * scale;

    // pressure_min is always 0.0
    if (@available(iOS 9, *)) {
      // These properties were introduced in iOS 9.0.
      pointer_data.pressure = touch.force;
      pointer_data.pressure_max = touch.maximumPossibleForce;
    } else {
      pointer_data.pressure = 1.0;
      pointer_data.pressure_max = 1.0;
    }

    // These properties were introduced in iOS 8.0
    pointer_data.radius_major = touch.majorRadius;
    pointer_data.radius_min = touch.majorRadius - touch.majorRadiusTolerance;
    pointer_data.radius_max = touch.majorRadius + touch.majorRadiusTolerance;

    // These properties were introduced in iOS 9.1
    if (@available(iOS 9.1, *)) {
      // iOS Documentation: altitudeAngle
      // A value of 0 radians indicates that the stylus is parallel to the surface. The value of
      // this property is Pi/2 when the stylus is perpendicular to the surface.
      //
      // PointerData Documentation: tilt
      // The angle of the stylus, in radians in the range:
      //    0 <= tilt <= pi/2
      // giving the angle of the axis of the stylus, relative to the axis perpendicular to the input
      // surface (thus 0.0 indicates the stylus is orthogonal to the plane of the input surface,
      // while pi/2 indicates that the stylus is flat on that surface).
      //
      // Discussion:
      // The ranges are the same. Origins are swapped.
      pointer_data.tilt = M_PI_2 - touch.altitudeAngle;

      // iOS Documentation: azimuthAngleInView:
      // With the tip of the stylus touching the screen, the value of this property is 0 radians
      // when the cap end of the stylus (that is, the end opposite of the tip) points along the
      // positive x axis of the device's screen. The azimuth angle increases as the user swings the
      // cap end of the stylus in a clockwise direction around the tip.
      //
      // PointerData Documentation: orientation
      // The angle of the stylus, in radians in the range:
      //    -pi < orientation <= pi
      // giving the angle of the axis of the stylus projected onto the input surface, relative to
      // the positive y-axis of that surface (thus 0.0 indicates the stylus, if projected onto that
      // surface, would go from the contact point vertically up in the positive y-axis direction, pi
      // would indicate that the stylus would go down in the negative y-axis direction; pi/4 would
      // indicate that the stylus goes up and to the right, -pi/2 would indicate that the stylus
      // goes to the left, etc).
      //
      // Discussion:
      // Sweep direction is the same. Phase of M_PI_2.
      pointer_data.orientation = [touch azimuthAngleInView:nil] - M_PI_2;
    }

    packet->SetPointerData(i++, pointer_data);
  }

  _shell->GetTaskRunners().GetUITaskRunner()->PostTask(
      fxl::MakeCopyable([engine = _shell->GetEngine(), packet = std::move(packet)] {
        if (engine) {
          engine->DispatchPointerDataPacket(*packet);
        }
      }));
}

- (void)touchesBegan:(NSSet*)touches withEvent:(UIEvent*)event {
  [self dispatchTouches:touches phase:UITouchPhaseBegan];
}

- (void)touchesMoved:(NSSet*)touches withEvent:(UIEvent*)event {
  [self dispatchTouches:touches phase:UITouchPhaseMoved];
}

- (void)touchesEnded:(NSSet*)touches withEvent:(UIEvent*)event {
  [self dispatchTouches:touches phase:UITouchPhaseEnded];
}

- (void)touchesCancelled:(NSSet*)touches withEvent:(UIEvent*)event {
  [self dispatchTouches:touches phase:UITouchPhaseCancelled];
}

#pragma mark - Handle view resizing

- (void)updateViewportMetrics {
  _shell->GetTaskRunners().GetUITaskRunner()->PostTask(
      [engine = _shell->GetEngine(), metrics = _viewportMetrics]() {
        if (engine) {
          engine->SetViewportMetrics(std::move(metrics));
        }
      });
}

- (CGFloat)statusBarPadding {
  UIScreen* screen = self.view.window.screen;
  CGRect statusFrame = [UIApplication sharedApplication].statusBarFrame;
  CGRect viewFrame =
      [self.view convertRect:self.view.bounds toCoordinateSpace:screen.coordinateSpace];
  CGRect intersection = CGRectIntersection(statusFrame, viewFrame);
  return CGRectIsNull(intersection) ? 0.0 : intersection.size.height;
}

- (void)viewDidLayoutSubviews {
  CGSize viewSize = self.view.bounds.size;
  CGFloat scale = [UIScreen mainScreen].scale;

  // First time since creation that the dimensions of its view is known.
  bool firstViewBoundsUpdate = !_viewportMetrics.physical_width;
  _viewportMetrics.device_pixel_ratio = scale;
  _viewportMetrics.physical_width = viewSize.width * scale;
  _viewportMetrics.physical_height = viewSize.height * scale;

  [self updateViewportPadding];
  [self updateViewportMetrics];

  // This must run after updateViewportMetrics so that the surface creation tasks are queued after
  // the viewport metrics update tasks.
  if (firstViewBoundsUpdate)
    [self surfaceUpdated:YES];
}

- (void)viewSafeAreaInsetsDidChange {
  [self updateViewportPadding];
  [self updateViewportMetrics];
  [super viewSafeAreaInsetsDidChange];
}

// Updates _viewportMetrics physical padding.
//
// Viewport padding represents the iOS safe area insets.
- (void)updateViewportPadding {
  CGFloat scale = [UIScreen mainScreen].scale;
  if (@available(iOS 11, *)) {
    _viewportMetrics.physical_padding_top = self.view.safeAreaInsets.top * scale;
    _viewportMetrics.physical_padding_left = self.view.safeAreaInsets.left * scale;
    _viewportMetrics.physical_padding_right = self.view.safeAreaInsets.right * scale;
    _viewportMetrics.physical_padding_bottom = self.view.safeAreaInsets.bottom * scale;
  } else {
    _viewportMetrics.physical_padding_top = [self statusBarPadding] * scale;
  }
}

#pragma mark - Keyboard events

- (void)keyboardWillChangeFrame:(NSNotification*)notification {
  NSDictionary* info = [notification userInfo];
  CGFloat bottom = CGRectGetHeight([[info objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue]);
  CGFloat scale = [UIScreen mainScreen].scale;
  _viewportMetrics.physical_view_inset_bottom = bottom * scale;
  [self updateViewportMetrics];
}

- (void)keyboardWillBeHidden:(NSNotification*)notification {
  _viewportMetrics.physical_view_inset_bottom = 0;
  [self updateViewportMetrics];
}

#pragma mark - Text input delegate

- (void)updateEditingClient:(int)client withState:(NSDictionary*)state {
  [_textInputChannel.get() invokeMethod:@"TextInputClient.updateEditingState"
                              arguments:@[ @(client), state ]];
}

- (void)performAction:(FlutterTextInputAction)action withClient:(int)client {
  NSString* actionString;
  switch (action) {
    case FlutterTextInputActionDone:
      actionString = @"TextInputAction.done";
      break;
    case FlutterTextInputActionNewline:
      actionString = @"TextInputAction.newline";
      break;
  }
  [_textInputChannel.get() invokeMethod:@"TextInputClient.performAction"
                              arguments:@[ @(client), actionString ]];
}

#pragma mark - Orientation updates

- (void)onOrientationPreferencesUpdated:(NSNotification*)notification {
  // Notifications may not be on the iOS UI thread
  dispatch_async(dispatch_get_main_queue(), ^{
    NSDictionary* info = notification.userInfo;

    NSNumber* update = info[@(shell::kOrientationUpdateNotificationKey)];

    if (update == nil) {
      return;
    }

    NSUInteger new_preferences = update.unsignedIntegerValue;

    if (new_preferences != _orientationPreferences) {
      _orientationPreferences = new_preferences;
      [UIViewController attemptRotationToDeviceOrientation];
    }
  });
}

- (BOOL)shouldAutorotate {
  return YES;
}

- (NSUInteger)supportedInterfaceOrientations {
  return _orientationPreferences;
}

#pragma mark - Accessibility

- (void)onAccessibilityStatusChanged:(NSNotification*)notification {
#if TARGET_OS_SIMULATOR
  // There doesn't appear to be any way to determine whether the accessibility
  // inspector is enabled on the simulator. We conservatively always turn on the
  // accessibility bridge in the simulator.
  bool enabled = true;
#else
  bool enabled = UIAccessibilityIsVoiceOverRunning() || UIAccessibilityIsSwitchControlRunning() ||
                 UIAccessibilityIsSpeakScreenEnabled();
#endif
  _shell->GetPlatformView()->SetSemanticsEnabled(enabled);
}

#pragma mark - Memory Notifications

- (void)onMemoryWarning:(NSNotification*)notification {
  [_systemChannel.get() sendMessage:@{@"type" : @"memoryPressure"}];
}

#pragma mark - Locale updates

- (void)onLocaleUpdated:(NSNotification*)notification {
  NSLocale* currentLocale = [NSLocale currentLocale];
  NSString* languageCode = [currentLocale objectForKey:NSLocaleLanguageCode];
  NSString* countryCode = [currentLocale objectForKey:NSLocaleCountryCode];
  if (languageCode && countryCode)
    [_localizationChannel.get() invokeMethod:@"setLocale" arguments:@[ languageCode, countryCode ]];
}

#pragma mark - Set user settings

- (void)onUserSettingsChanged:(NSNotification*)notification {
  [_settingsChannel.get() sendMessage:@{
    @"textScaleFactor" : @([self textScaleFactor]),
    @"alwaysUse24HourFormat" : @([self isAlwaysUse24HourFormat]),
  }];
}

- (CGFloat)textScaleFactor {
  UIContentSizeCategory category = [UIApplication sharedApplication].preferredContentSizeCategory;
  // The delta is computed by approximating Apple's typography guidelines:
  // https://developer.apple.com/ios/human-interface-guidelines/visual-design/typography/
  //
  // Specifically:
  // Non-accessibility sizes for "body" text are:
  const CGFloat xs = 14;
  const CGFloat s = 15;
  const CGFloat m = 16;
  const CGFloat l = 17;
  const CGFloat xl = 19;
  const CGFloat xxl = 21;
  const CGFloat xxxl = 23;

  // Accessibility sizes for "body" text are:
  const CGFloat ax1 = 28;
  const CGFloat ax2 = 33;
  const CGFloat ax3 = 40;
  const CGFloat ax4 = 47;
  const CGFloat ax5 = 53;

  // We compute the scale as relative difference from size L (large, the default size), where
  // L is assumed to have scale 1.0.
  if ([category isEqualToString:UIContentSizeCategoryExtraSmall])
    return xs / l;
  else if ([category isEqualToString:UIContentSizeCategorySmall])
    return s / l;
  else if ([category isEqualToString:UIContentSizeCategoryMedium])
    return m / l;
  else if ([category isEqualToString:UIContentSizeCategoryLarge])
    return 1.0;
  else if ([category isEqualToString:UIContentSizeCategoryExtraLarge])
    return xl / l;
  else if ([category isEqualToString:UIContentSizeCategoryExtraExtraLarge])
    return xxl / l;
  else if ([category isEqualToString:UIContentSizeCategoryExtraExtraExtraLarge])
    return xxxl / l;
  else if ([category isEqualToString:UIContentSizeCategoryAccessibilityMedium])
    return ax1 / l;
  else if ([category isEqualToString:UIContentSizeCategoryAccessibilityLarge])
    return ax2 / l;
  else if ([category isEqualToString:UIContentSizeCategoryAccessibilityExtraLarge])
    return ax3 / l;
  else if ([category isEqualToString:UIContentSizeCategoryAccessibilityExtraExtraLarge])
    return ax4 / l;
  else if ([category isEqualToString:UIContentSizeCategoryAccessibilityExtraExtraExtraLarge])
    return ax5 / l;
  else
    return 1.0;
}

- (BOOL)isAlwaysUse24HourFormat {
  // iOS does not report its "24-Hour Time" user setting in the API. Instead, it applies
  // it automatically to NSDateFormatter when used with [NSLocale currentLocale]. It is
  // essential that [NSLocale currentLocale] is used. Any custom locale, even the one
  // that's the same as [NSLocale currentLocale] will ignore the 24-hour option (there
  // must be some internal field that's not exposed to developers).
  //
  // Therefore this option behaves differently across Android and iOS. On Android this
  // setting is exposed standalone, and can therefore be applied to all locales, whether
  // the "current system locale" or a custom one. On iOS it only applies to the current
  // system locale. Widget implementors must take this into account in order to provide
  // platform-idiomatic behavior in their widgets.
  NSString* dateFormat =
      [NSDateFormatter dateFormatFromTemplate:@"j" options:0 locale:[NSLocale currentLocale]];
  return [dateFormat rangeOfString:@"a"].location == NSNotFound;
}

#pragma mark - Status Bar touch event handling

// Standard iOS status bar height in pixels.
constexpr CGFloat kStandardStatusBarHeight = 20.0;

- (void)handleStatusBarTouches:(UIEvent*)event {
  CGFloat standardStatusBarHeight = kStandardStatusBarHeight;
  if (@available(iOS 11, *)) {
    standardStatusBarHeight = self.view.safeAreaInsets.top;
  }

  // If the status bar is double-height, don't handle status bar taps. iOS
  // should open the app associated with the status bar.
  CGRect statusBarFrame = [UIApplication sharedApplication].statusBarFrame;
  if (statusBarFrame.size.height != standardStatusBarHeight) {
    return;
  }

  // If we detect a touch in the status bar, synthesize a fake touch begin/end.
  for (UITouch* touch in event.allTouches) {
    if (touch.phase == UITouchPhaseBegan && touch.tapCount > 0) {
      CGPoint windowLoc = [touch locationInView:nil];
      CGPoint screenLoc = [touch.window convertPoint:windowLoc toWindow:nil];
      if (CGRectContainsPoint(statusBarFrame, screenLoc)) {
        NSSet* statusbarTouches = [NSSet setWithObject:touch];
        [self dispatchTouches:statusbarTouches phase:UITouchPhaseBegan];
        [self dispatchTouches:statusbarTouches phase:UITouchPhaseEnded];
        return;
      }
    }
  }
}

#pragma mark - Status bar style

- (UIStatusBarStyle)preferredStatusBarStyle {
  return _statusBarStyle;
}

- (void)onPreferredStatusBarStyleUpdated:(NSNotification*)notification {
  // Notifications may not be on the iOS UI thread
  dispatch_async(dispatch_get_main_queue(), ^{
    NSDictionary* info = notification.userInfo;

    NSNumber* update = info[@(shell::kOverlayStyleUpdateNotificationKey)];

    if (update == nil) {
      return;
    }

    NSInteger style = update.integerValue;

    if (style != _statusBarStyle) {
      _statusBarStyle = static_cast<UIStatusBarStyle>(style);
      [self setNeedsStatusBarAppearanceUpdate];
    }
  });
}

#pragma mark - FlutterBinaryMessenger

- (void)sendOnChannel:(NSString*)channel message:(NSData*)message {
  [self sendOnChannel:channel message:message binaryReply:nil];
}

- (void)sendOnChannel:(NSString*)channel
              message:(NSData*)message
          binaryReply:(FlutterBinaryReply)callback {
  NSAssert(channel, @"The channel must not be null");
  fxl::RefPtr<shell::PlatformMessageResponseDarwin> response =
      (callback == nil) ? nullptr
                        : fxl::MakeRefCounted<shell::PlatformMessageResponseDarwin>(
                              ^(NSData* reply) {
                                callback(reply);
                              },
                              _shell->GetTaskRunners().GetPlatformTaskRunner());
  fxl::RefPtr<blink::PlatformMessage> platformMessage =
      (message == nil) ? fxl::MakeRefCounted<blink::PlatformMessage>(channel.UTF8String, response)
                       : fxl::MakeRefCounted<blink::PlatformMessage>(
                             channel.UTF8String, shell::GetVectorFromNSData(message), response);

  _shell->GetPlatformView()->DispatchPlatformMessage(platformMessage);
}

- (void)setMessageHandlerOnChannel:(NSString*)channel
              binaryMessageHandler:(FlutterBinaryMessageHandler)handler {
  NSAssert(channel, @"The channel must not be null");
  [self iosPlatformView] -> GetPlatformMessageRouter().SetMessageHandler(channel.UTF8String,
                                                                         handler);
}

#pragma mark - FlutterTextureRegistry

- (int64_t)registerTexture:(NSObject<FlutterTexture>*)texture {
  int64_t textureId = _nextTextureId++;
  [self iosPlatformView] -> RegisterExternalTexture(textureId, texture);
  return textureId;
}

- (void)unregisterTexture:(int64_t)textureId {
  _shell->GetPlatformView()->UnregisterTexture(textureId);
}

- (void)textureFrameAvailable:(int64_t)textureId {
  _shell->GetPlatformView()->MarkTextureFrameAvailable(textureId);
}

- (NSString*)lookupKeyForAsset:(NSString*)asset {
  return [FlutterDartProject lookupKeyForAsset:asset];
}

- (NSString*)lookupKeyForAsset:(NSString*)asset fromPackage:(NSString*)package {
  return [FlutterDartProject lookupKeyForAsset:asset fromPackage:package];
}

- (id<FlutterPluginRegistry>)pluginRegistry {
  return self;
}

#pragma mark - FlutterPluginRegistry

- (NSObject<FlutterPluginRegistrar>*)registrarForPlugin:(NSString*)pluginKey {
  NSAssert(self.pluginPublications[pluginKey] == nil, @"Duplicate plugin key: %@", pluginKey);
  self.pluginPublications[pluginKey] = [NSNull null];
  return
      [[FlutterViewControllerRegistrar alloc] initWithPlugin:pluginKey flutterViewController:self];
}

- (BOOL)hasPlugin:(NSString*)pluginKey {
  return _pluginPublications[pluginKey] != nil;
}

- (NSObject*)valuePublishedByPlugin:(NSString*)pluginKey {
  return _pluginPublications[pluginKey];
}
@end

@implementation FlutterViewControllerRegistrar {
  NSString* _pluginKey;
  FlutterViewController* _flutterViewController;
}

- (instancetype)initWithPlugin:(NSString*)pluginKey
         flutterViewController:(FlutterViewController*)flutterViewController {
  self = [super init];
  NSAssert(self, @"Super init cannot be nil");
  _pluginKey = [pluginKey retain];
  _flutterViewController = [flutterViewController retain];
  return self;
}

- (void)dealloc {
  [_pluginKey release];
  [_flutterViewController release];
  [super dealloc];
}

- (NSObject<FlutterBinaryMessenger>*)messenger {
  return _flutterViewController;
}

- (NSObject<FlutterTextureRegistry>*)textures {
  return _flutterViewController;
}

- (void)publish:(NSObject*)value {
  _flutterViewController.pluginPublications[_pluginKey] = value;
}

- (void)addMethodCallDelegate:(NSObject<FlutterPlugin>*)delegate
                      channel:(FlutterMethodChannel*)channel {
  [channel setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
    [delegate handleMethodCall:call result:result];
  }];
}

- (void)addApplicationDelegate:(NSObject<FlutterPlugin>*)delegate {
  id<UIApplicationDelegate> appDelegate = [[UIApplication sharedApplication] delegate];
  if ([appDelegate conformsToProtocol:@protocol(FlutterAppLifeCycleProvider)]) {
    id<FlutterAppLifeCycleProvider> lifeCycleProvider =
        (id<FlutterAppLifeCycleProvider>)appDelegate;
    [lifeCycleProvider addApplicationLifeCycleDelegate:delegate];
  }
}

- (NSString*)lookupKeyForAsset:(NSString*)asset {
  return [_flutterViewController lookupKeyForAsset:asset];
}

- (NSString*)lookupKeyForAsset:(NSString*)asset fromPackage:(NSString*)package {
  return [_flutterViewController lookupKeyForAsset:asset fromPackage:package];
}

@end
