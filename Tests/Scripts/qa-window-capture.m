#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

// This observer runs inside the driver's disposable, re-signed copy of the app.
// ScreenCaptureKit can capture its own window without recording the user's desktop.
__attribute__((constructor)) static void installCapture(void) {
    @autoreleasepool {
        NSString *path = NSProcessInfo.processInfo.environment[@"SWARMHUB_QA_SNAPSHOT_PATH"];
        unsetenv("DYLD_INSERT_LIBRARIES");
        if (!path.length || ![NSBundle.mainBundle.bundleIdentifier hasPrefix:@"com.konrad.agentapp.window-qa."]) return;
        if (![SCShareableContent respondsToSelector:@selector(getCurrentProcessShareableContentWithCompletionHandler:)]) return;
        NSString *request = [path stringByAppendingString:@".request"];
        dispatch_async(dispatch_get_main_queue(), ^{
            static BOOL busy = NO;
            [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) {
                if (busy || ![[NSFileManager defaultManager] fileExistsAtPath:request]) return;
                NSWindow *target = NSApp.keyWindow ?: NSApp.mainWindow;
                if (!target) {
                    for (NSWindow *candidate in NSApp.windows) {
                        if (candidate.isVisible && candidate.canBecomeMainWindow) { target = candidate; break; }
                    }
                }
                if (!target) return;
                busy = YES;
                NSInteger number = target.windowNumber;
                CGFloat scale = target.backingScaleFactor;
                [SCShareableContent getCurrentProcessShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *err) {
                    for (SCWindow *window in content.windows) {
                        if (window.windowID != number) continue;
                        SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
                        SCStreamConfiguration *settings = [SCStreamConfiguration new];
                        settings.width = window.frame.size.width * scale;
                        settings.height = window.frame.size.height * scale;
                        settings.showsCursor = NO;
                        settings.ignoreShadowsSingleWindow = YES;
                        [SCScreenshotManager captureImageWithFilter:filter configuration:settings completionHandler:^(CGImageRef img, NSError *problem) {
                            if (img) {
                                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
                                if ([[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES])
                                    [[NSFileManager defaultManager] removeItemAtPath:request error:nil];
                            } else { NSLog(@"Current process capture: %@", problem.localizedDescription); }
                            dispatch_async(dispatch_get_main_queue(), ^{ busy = NO; });
                        }];
                        return;
                    }
                    NSLog(@"Current process window missing: %@", err.localizedDescription);
                    dispatch_async(dispatch_get_main_queue(), ^{ busy = NO; });
                }];
            }];
        });
    }
}
