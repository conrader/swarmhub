#!/bin/zsh
# Run against a packaged SwarmHub.app. The scratch copy uses its own preferences.
# Simulate Sparkle being busy at launch and record manual requests without fetching an update.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE_APP="${1:?Usage: Tests/Scripts/update-menu-test.sh /path/to/SwarmHub.app}"
WORK="$(mktemp -d /tmp/swarmhub-update-menu.XXXXXX)"
APP="$WORK/SwarmHub.app"
DOMAIN="com.konrad.agentapp.update-menu-test.$$"
APP_PID=""
cleanup() {
  if [[ -n "$APP_PID" ]]; then kill "$APP_PID" 2>/dev/null || true; fi
  defaults delete "$DOMAIN" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

ditto "$SOURCE_APP" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DOMAIN" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

xcrun clang -fobjc-arc -dynamiclib -framework AppKit -x objective-c -o "$WORK/probe.dylib" - <<'PROBE'
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static BOOL (*startUpdater)(id, SEL, NSError **);
static id updater;
static unsigned requests;

static BOOL startBusy(id instance, SEL selector, NSError **error) {
    if (!startUpdater(instance, selector, error)) return NO;
    updater = instance;
    [updater setValue:@NO forKey:@"canCheckForUpdates"];
    return YES;
}

static void recordRequest(id instance, SEL selector) {
    if (![[instance valueForKey:@"canCheckForUpdates"] boolValue]) {
        fputs("Manual check reached Sparkle while busy\n", stderr);
        exit(1);
    }
    requests++;
}

static void testMenu(int remaining) {
    NSMenu *menu = NSApp.mainMenu.itemArray.firstObject.submenu;
    NSMenuItem *item = [menu itemWithTitle:@"Check for Updates…"];
    if ((!updater || !item) && remaining > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
            testMenu(remaining - 1);
        });
        return;
    }
    [menu update];
    if (!updater || !item.isEnabled) {
        fputs("Check for Updates menu item is unavailable while Sparkle is starting\n", stderr);
        exit(1);
    }
    [menu performActionForItemAtIndex:[menu indexOfItem:item]];
    [menu performActionForItemAtIndex:[menu indexOfItem:item]];
    [updater setValue:@YES forKey:@"canCheckForUpdates"];
    dispatch_async(dispatch_get_main_queue(), ^{
        fprintf(stderr, "Manual requests sent to Sparkle: %u (expected 1)\n", requests);
        exit(requests == 1 ? 0 : 1);
    });
}

__attribute__((constructor))
static void installProbe(void) {
    Class sparkle = NSClassFromString(@"SPUUpdater");
    Method start = class_getInstanceMethod(sparkle, sel_registerName("startUpdater:"));
    Method check = class_getInstanceMethod(sparkle, sel_registerName("checkForUpdates"));
    if (!start || !check) exit(1);
    startUpdater = (void *)method_setImplementation(start, (IMP)startBusy);
    method_setImplementation(check, (IMP)recordRequest);
    dispatch_async(dispatch_get_main_queue(), ^{ testMenu(80); });
}
PROBE

mkdir "$WORK/home"
(
  cd "$ROOT_DIR"
  exec env CFFIXED_USER_HOME="$WORK/home" DYLD_INSERT_LIBRARIES="$WORK/probe.dylib" \
    "$APP/Contents/MacOS/AgentApp" -SUEnableAutomaticChecks NO -SUAutomaticallyUpdate NO
) &
APP_PID=$!
wait "$APP_PID"
APP_PID=""
