/*
 **  PTYWindow.m
 **
 **  Copyright (c) 2002, 2003
 **
 **  Author: Fabian, Ujwal S. Setlur
 **      Initial code by Kiichi Kusama
 **
 **  This program is free software; you can redistribute it and/or modify
 **  it under the terms of the GNU General Public License as published by
 **  the Free Software Foundation; either version 2 of the License, or
 **  (at your option) any later version.
 **
 **  This program is distributed in the hope that it will be useful,
 **  but WITHOUT ANY WARRANTY; without even the implied warranty of
 **  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 **  GNU General Public License for more details.
 **
 **  You should have received a copy of the GNU General Public License
 **  along with this program; if not, write to the Free Software
 **  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 */

#import "iTerm.h"
#import "PTYWindow.h"
#import "PreferencePanel.h"
#import "PseudoTerminal.h"
#import "FutureMethods.h"
#import "iTermController.h"
#import "iTermApplicationDelegate.h"
#import "iTermSettingsModel.h"

#ifdef PSEUDOTERMINAL_VERBOSE_LOGGING
#define PtyLog NSLog
#else
#define PtyLog DLog
#endif

@implementation PTYWindow {
    int blurFilter;
    double blurRadius_;
    BOOL layoutDone;
    
    // True while in -[NSWindow toggleFullScreen:].
    BOOL isTogglingLionFullScreen_;
    NSObject *restoreState_;
}

- (void)dealloc
{
    [restoreState_ release];
    [super dealloc];

}

- (id)initWithContentRect:(NSRect)contentRect
                styleMask:(NSUInteger)aStyle
                  backing:(NSBackingStoreType)bufferingType
                    defer:(BOOL)flag {
    self = [super initWithContentRect:contentRect
                            styleMask:aStyle
                              backing:bufferingType
                                defer:flag];
    if (self) {
        [self setAlphaValue:0.9999];
        blurFilter = 0;
        layoutDone = NO;
    }

    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p frame=%@>",
            [self class],
            self,
            [NSValue valueWithRect:self.frame]];
}

- (void)encodeRestorableStateWithCoder:(NSCoder *)coder {
    // This gives a warning, but this method won't be called except in 10.7 where this
    // method does exist in our superclass. The only way to avoid the warning
    // is to do some really gnarly stuff. See here for more:
    // http://www.cocoabuilder.com/archive/cocoa/214903-using-performselector-on-super.html
    [super encodeRestorableStateWithCoder:coder];
    [coder encodeObject:restoreState_ forKey:@"ptyarrangement"];
}

- (void)setRestoreState:(NSObject *)restoreState {
    [restoreState_ autorelease];
    restoreState_ = [restoreState retain];
}

- (void)enableBlur:(double)radius {
    const double kEpsilon = 0.001;
    if (blurFilter && fabs(blurRadius_ - radius) < kEpsilon) {
        return;
    }

    CGSConnectionID con = CGSMainConnectionID();
    if (!con) {
        return;
    }
    CGSSetWindowBackgroundBlurRadiusFunction* function = GetCGSSetWindowBackgroundBlurRadiusFunction();
    if (function) {
        function(con, [self windowNumber], (int)radius);
    } else {
        NSLog(@"Couldn't get blur function");
    }
    blurRadius_ = radius;
}

- (void)disableBlur {
    CGSConnectionID con = CGSMainConnectionID();
    if (!con) {
        return;
    }

    CGSSetWindowBackgroundBlurRadiusFunction* function = GetCGSSetWindowBackgroundBlurRadiusFunction();
    if (function) {
        function(con, [self windowNumber], 0);
    } else if (blurFilter) {
        CGSRemoveWindowFilter(con, (CGSWindowID)[self windowNumber], blurFilter);
        CGSReleaseCIFilter(CGSMainConnectionID(), blurFilter);
        blurFilter = 0;
    }
}

- (id<PTYWindowDelegateProtocol>)ptyDelegate {
    return (id<PTYWindowDelegateProtocol>)[self delegate];
}

- (void)toggleFullScreen:(id)sender {
    if (![[self ptyDelegate] lionFullScreen]  &&
        ![[PreferencePanel sharedInstance] lionStyleFullscreen]) {
        // The user must have clicked on the toolbar arrow, but the pref is set
        // to use traditional fullscreen.
        [[self delegate] performSelector:@selector(toggleTraditionalFullScreenMode)
                              withObject:nil];
    } else {
        [super toggleFullScreen:sender];
    }
}

- (BOOL)isTogglingLionFullScreen {
    return isTogglingLionFullScreen_;
}

- (int)screenNumber {
    return [[[[self screen] deviceDescription] objectForKey:@"NSScreenNumber"] intValue];
}

- (void)smartLayout {
    PtyLog(@"enter smartLayout");
    NSEnumerator* iterator;

    CGSWorkspaceID currentSpace = -1;  // Valid only before 10.8 Mountain Lion.
    CGSConnectionID con;
    if (!IsMountainLionOrLater()) {
        con = CGSMainConnectionID();
        if (!con) {
            PtyLog(@"CGSMainConnectionID failed");
            return;
        }
        CGSGetWorkspace(con, &currentSpace);
    }

    int currentScreen = [self screenNumber];
    NSRect screenRect = [[self screen] visibleFrame];

    // Get a list of relevant windows, same screen & workspace
    NSMutableArray* windows = [[NSMutableArray alloc] init];
    iterator = [[[iTermController sharedInstance] terminals] objectEnumerator];
    PseudoTerminal* term;
    PtyLog(@"Begin iterating over terminals");
    while ((term = [iterator nextObject])) {
        PTYWindow* otherWindow = (PTYWindow*)[term window];
        PtyLog(@"See window %@ at %@", otherWindow, [NSValue valueWithRect:[otherWindow frame]]);
        if (otherWindow == self) {
            PtyLog(@" skip - is self");
            continue;
        }
        int otherScreen = [otherWindow screenNumber];
        if (otherScreen != currentScreen) {
            PtyLog(@" skip - screen %d vs my %d", otherScreen, currentScreen);
            continue;
        }

        if (IsMountainLionOrLater()) {
            // CGSGetWindowWorkspace broke in 10.8.
            if (![otherWindow isOnActiveSpace]) {
                PtyLog(@"  skip - not in active space");
                continue;
            }
        } else {
            CGSWorkspaceID otherSpace = -1;
            CGSGetWindowWorkspace(con, [otherWindow windowNumber], &otherSpace);
            if (otherSpace != currentSpace) {
                PtyLog(@" skip - different space %d vs my %d", otherSpace, currentSpace);
                continue;
            }
        }

        PtyLog(@" add window to array of windows");
        [windows addObject:otherWindow];
    }


    // Find the spot on screen with the lowest window intersection
    float bestIntersect = INFINITY;
    NSRect bestFrame = [self frame];

    NSRect placementRect = NSMakeRect(
        screenRect.origin.x,
        screenRect.origin.y,
        MAX(1, screenRect.size.width-[self frame].size.width),
        MAX(1, screenRect.size.height-[self frame].size.height)
    );
    PtyLog(@"PlacementRect is %@", [NSValue valueWithRect:placementRect]);

    for(int x = 0; x < placementRect.size.width/2; x += 50) {
        for(int y = 0; y < placementRect.size.height/2; y += 50) {
            PtyLog(@"Try coord %d,%d", x, y);

            NSRect testRects[4] = {[self frame]};

            // Top Left
            testRects[0].origin.x = placementRect.origin.x + x;
            testRects[0].origin.y = placementRect.origin.y + placementRect.size.height - y;

            // Top Right
            testRects[1] = testRects[0];
            testRects[1].origin.x = placementRect.origin.x + placementRect.size.width - x;

            // Bottom Left
            testRects[2] = testRects[0];
            testRects[2].origin.y = placementRect.origin.y + y;

            // Bottom Right
            testRects[3] = testRects[1];
            testRects[3].origin.y = placementRect.origin.y + y;

            for (int i = 0; i < sizeof(testRects)/sizeof(NSRect); i++) {
                PtyLog(@"compute badness of test rect %d %@", i, [NSValue valueWithRect:testRects[i]]);

                iterator = [windows objectEnumerator];
                PTYWindow* other;
                float badness = 0.0f;
                while ((other = [iterator nextObject])) {
                    NSRect otherFrame = [other frame];
                    NSRect intersection = NSIntersectionRect(testRects[i], otherFrame);
                    badness += intersection.size.width * intersection.size.height;
                    PtyLog(@"badness of %@ is %.2f", other, intersection.size.width * intersection.size.height);
                }


                char const * names[] = {"TL", "TR", "BL", "BR"};
                PtyLog(@"%s: testRect:%@, bad:%.2f",
                        names[i], NSStringFromRect(testRects[i]), badness);

                if (badness < bestIntersect) {
                    PtyLog(@"This is the best coordinate found so far");
                    bestIntersect = badness;
                    bestFrame = testRects[i];
                }

                // Shortcut if we've found an empty spot
                if (bestIntersect == 0) {
                    PtyLog(@"zero badness. Done.");
                    goto end;
                }
            }
        }
    }

end:
    [windows release];
    PtyLog(@"set frame origin to %@", [NSValue valueWithPoint:bestFrame.origin]);
    [self setFrameOrigin:bestFrame.origin];
}

- (void)setLayoutDone {
    PtyLog(@"setLayoutDone %@", [NSThread callStackSymbols]);
    layoutDone = YES;
}

- (void)makeKeyAndOrderFront:(id)sender {
    PtyLog(@"PTYWindow makeKeyAndOrderFront: layoutDone=%d %@", (int)layoutDone, [NSThread callStackSymbols]);
    if (!layoutDone) {
        PtyLog(@"try to call windowWillShowInitial");
        [self setLayoutDone];
        if ([[self delegate] respondsToSelector:@selector(windowWillShowInitial)]) {
            [[self delegate] performSelector:@selector(windowWillShowInitial)];
        } else {
            PtyLog(@"delegate %@ does not respond", [self delegate]);
        }
    }
    PtyLog(@"PTYWindow - calling makeKeyAndOrderFont, which triggers a window resize");
    PtyLog(@"The current window frame is %fx%f", [self frame].size.width, [self frame].size.height);
    [super makeKeyAndOrderFront:sender];
}

- (void)setToolbar:(NSToolbar *)toolbar {
    if ([iTermSettingsModel disableToolbar]) {
        return;
    }
    [super setToolbar:toolbar];
}

- (void)toggleToolbarShown:(id)sender {
    id delegate = [self delegate];

    // Let our delegate know
    if([delegate conformsToProtocol: @protocol(PTYWindowDelegateProtocol)])
    [delegate windowWillToggleToolbarVisibility: self];

    [super toggleToolbarShown: sender];

    // Let our delegate know
    if([delegate conformsToProtocol: @protocol(PTYWindowDelegateProtocol)])
    [delegate windowDidToggleToolbarVisibility: self];

}

- (BOOL)canBecomeKeyWindow {
    return YES;
}

@end
