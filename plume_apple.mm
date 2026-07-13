//
// plume
//
// Copyright (c) 2024 renderbag and contributors. All rights reserved.
// Licensed under the MIT license. See LICENSE file for details.
//

#include "plume_apple.h"

#import <Foundation/Foundation.h>

#include <chrono>
#include <cmath>

#if TARGET_OS_IPHONE
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#import <IOKit/IOKitLib.h>
#endif

#if TARGET_OS_IPHONE
@interface PlumeMetalView : UIView
@end

@implementation PlumeMetalView
+ (Class)layerClass {
    return CAMetalLayer.class;
}
@end
#endif

namespace {
    using WindowState = std::shared_ptr<plume::CocoaWindowState>;

    constexpr int64_t AttributesRefreshIntervalNs = 100'000'000;
    constexpr int64_t RefreshRateIntervalNs = 1'000'000'000;

    int64_t monotonicTimeNs() {
        return std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
    }

#if TARGET_OS_IPHONE
    UIWindow* activeWindow() {
        UIApplication* application = UIApplication.sharedApplication;
        for (UIScene* scene in application.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive ||
                ![scene isKindOfClass:UIWindowScene.class]) {
                continue;
            }

            UIWindowScene* windowScene = (UIWindowScene*)scene;
            for (UIWindow* window in windowScene.windows) {
                if (window.isKeyWindow) {
                    return window;
                }
            }

            if (windowScene.windows.count > 0) {
                return windowScene.windows.firstObject;
            }
        }

        return application.windows.firstObject;
    }

    UIWindow* resolveWindow(void* windowHandle) {
        if (windowHandle != nullptr) {
            id object = (__bridge id)windowHandle;
            if ([object isKindOfClass:UIWindow.class]) {
                return (UIWindow*)object;
            }
        }

        return activeWindow();
    }

    CGFloat scaleFactor(UIWindow* window) {
#ifdef APPLE_RETINA_ENABLED
        UIScreen* screen = window.screen ?: UIScreen.mainScreen;
        return screen.nativeScale;
#else
        return 1.0f;
#endif
    }

    void updateWindowAttributes(const WindowState& state) {
        UIWindow* window = resolveWindow(state->windowHandle);
        UIView* contentView = window.rootViewController.view ?: window;
        const CGRect bounds = contentView.bounds;
        const CGFloat scale = scaleFactor(window);

        std::lock_guard<std::mutex> lock(state->attributesMutex);
        state->cachedAttributes.x = static_cast<int>(std::round(bounds.origin.x));
        state->cachedAttributes.y = static_cast<int>(std::round(bounds.origin.y));
        state->cachedAttributes.width = static_cast<int>(std::round(bounds.size.width * scale));
        state->cachedAttributes.height = static_cast<int>(std::round(bounds.size.height * scale));
    }

    void updateRefreshRate(const WindowState& state) {
        UIWindow* window = resolveWindow(state->windowHandle);
        UIScreen* screen = window.screen ?: UIScreen.mainScreen;
        state->cachedRefreshRate.store(static_cast<int>(screen.maximumFramesPerSecond));
    }

    CAMetalLayer* findMetalLayer(CALayer* layer) {
        if ([layer isKindOfClass:CAMetalLayer.class]) {
            return (CAMetalLayer*)layer;
        }

        for (CALayer* child in layer.sublayers) {
            if (CAMetalLayer* result = findMetalLayer(child)) {
                return result;
            }
        }

        return nil;
    }

#else
    uint32_t getEntryProperty(io_registry_entry_t entry, CFStringRef propertyName) {
        uint32_t value = 0;
        CFTypeRef cfProp = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, propertyName,
            kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents);

        if (cfProp) {
            if (CFGetTypeID(cfProp) == CFDataGetTypeID()) {
                const uint32_t* propertyValue = reinterpret_cast<const uint32_t*>(CFDataGetBytePtr((CFDataRef)cfProp));
                if (propertyValue) {
                    value = *propertyValue;
                }
            }
            CFRelease(cfProp);
        }

        return value;
    }

    CGFloat scaleFactor(NSWindow* window) {
#ifdef APPLE_RETINA_ENABLED
        return window.backingScaleFactor;
#else
        return 1.0f;
#endif
    }

    void updateWindowAttributes(const WindowState& state) {
        NSWindow* window = (__bridge NSWindow*)state->windowHandle;
        const NSRect contentFrame = window.contentView.frame;
        const CGFloat scale = scaleFactor(window);

        std::lock_guard<std::mutex> lock(state->attributesMutex);
        state->cachedAttributes.x = static_cast<int>(std::round(contentFrame.origin.x));
        state->cachedAttributes.y = static_cast<int>(std::round(contentFrame.origin.y));
        state->cachedAttributes.width = static_cast<int>(std::round(contentFrame.size.width * scale));
        state->cachedAttributes.height = static_cast<int>(std::round(contentFrame.size.height * scale));
    }

    void updateRefreshRate(const WindowState& state) {
        if (@available(macOS 12.0, *)) {
            NSWindow* window = (__bridge NSWindow*)state->windowHandle;
            state->cachedRefreshRate.store(static_cast<int>(window.screen.maximumFramesPerSecond));
        }
    }
#endif
}

namespace plume {
    RenderDeviceVendor getRenderDeviceVendor(uint64_t registryID) {
#if TARGET_OS_IPHONE
        (void)registryID;
        return RenderDeviceVendor::APPLE;
#else
        io_service_t entry = IOServiceGetMatchingService(MACH_PORT_NULL, IORegistryEntryIDMatching(registryID));

        if (entry) {
            io_registry_entry_t parent;
            if (IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == kIOReturnSuccess) {
                uint32_t vendorId = getEntryProperty(parent, CFSTR("vendor-id"));
                IOObjectRelease(parent);
                IOObjectRelease(entry);
                return RenderDeviceVendor(vendorId);
            }
            IOObjectRelease(entry);
        }

        return RenderDeviceVendor::UNKNOWN;
#endif
    }

#if TARGET_OS_IPHONE
    void* ensureMetalLayerForIOSWindow(void* windowHandle) {
        __block CAMetalLayer* metalLayer = nil;
        auto findOrCreateLayer = ^{
            UIWindow* window = resolveWindow(windowHandle);
            UIView* contentView = window.rootViewController.view ?: window;
            if (contentView == nil) {
                return;
            }

            metalLayer = findMetalLayer(contentView.layer);
            if (metalLayer != nil) {
                return;
            }

            PlumeMetalView* metalView = [[PlumeMetalView alloc] initWithFrame:contentView.bounds];
            metalView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            metalView.userInteractionEnabled = NO;
            [contentView addSubview:metalView];

            metalLayer = (CAMetalLayer*)metalView.layer;
            metalLayer.contentsScale = scaleFactor(window);
            metalLayer.drawableSize = CGSizeMake(
                contentView.bounds.size.width * metalLayer.contentsScale,
                contentView.bounds.size.height * metalLayer.contentsScale);

#if !__has_feature(objc_arc)
            [metalView release];
#endif
        };

        if (NSThread.isMainThread) {
            findOrCreateLayer();
        } else {
            dispatch_sync(dispatch_get_main_queue(), findOrCreateLayer);
        }

        return (__bridge void*)metalLayer;
    }

    void setMetalLayerDrawableCount(void* layer, uint32_t drawableCount) {
        CAMetalLayer* metalLayer = (__bridge CAMetalLayer*)layer;
        metalLayer.maximumDrawableCount = drawableCount;
    }
#endif

    CocoaWindow::CocoaWindow(void* window)
        : state(std::make_shared<CocoaWindowState>()) {
        state->windowHandle = window;
        state->cachedAttributes = {0, 0, 0, 0};
        state->cachedRefreshRate.store(0);

        if (NSThread.isMainThread) {
            updateWindowAttributes(state);
            updateRefreshRate(state);
        } else {
            updateWindowAttributesInternal(true);
            updateRefreshRateInternal(true);
        }
    }

    CocoaWindow::~CocoaWindow() = default;

    void CocoaWindow::updateWindowAttributesInternal(bool forceSync) {
        WindowState windowState = state;
        auto updateBlock = ^{
            updateWindowAttributes(windowState);
            windowState->nextAttributesUpdateNs.store(monotonicTimeNs() + AttributesRefreshIntervalNs);
            windowState->attributesUpdatePending.store(false);
        };

        if (forceSync) {
            dispatch_sync(dispatch_get_main_queue(), updateBlock);
            return;
        }

        if (monotonicTimeNs() < windowState->nextAttributesUpdateNs.load()) {
            return;
        }

        bool expected = false;
        if (windowState->attributesUpdatePending.compare_exchange_strong(expected, true)) {
            dispatch_async(dispatch_get_main_queue(), updateBlock);
        }
    }

    void CocoaWindow::updateRefreshRateInternal(bool forceSync) {
        WindowState windowState = state;
        auto updateBlock = ^{
            updateRefreshRate(windowState);
            windowState->nextRefreshRateUpdateNs.store(monotonicTimeNs() + RefreshRateIntervalNs);
            windowState->refreshRateUpdatePending.store(false);
        };

        if (forceSync) {
            dispatch_sync(dispatch_get_main_queue(), updateBlock);
            return;
        }

        if (monotonicTimeNs() < windowState->nextRefreshRateUpdateNs.load()) {
            return;
        }

        bool expected = false;
        if (windowState->refreshRateUpdatePending.compare_exchange_strong(expected, true)) {
            dispatch_async(dispatch_get_main_queue(), updateBlock);
        }
    }

    void CocoaWindow::getWindowAttributes(CocoaWindowAttributes* attributes) const {
        if (NSThread.isMainThread) {
            updateWindowAttributes(state);
        } else {
            const_cast<CocoaWindow*>(this)->updateWindowAttributesInternal(false);
        }

        std::lock_guard<std::mutex> lock(state->attributesMutex);
        *attributes = state->cachedAttributes;
    }

    int CocoaWindow::getRefreshRate() const {
        if (NSThread.isMainThread) {
            updateRefreshRate(state);
        } else {
            const_cast<CocoaWindow*>(this)->updateRefreshRateInternal(false);
        }

        return state->cachedRefreshRate.load();
    }

    void CocoaWindow::toggleFullscreen() {
#if TARGET_OS_IPHONE
        // iOS windows are always managed by UIKit.
#else
        void* windowHandle = state->windowHandle;
        auto toggleBlock = ^{
            NSWindow* window = (__bridge NSWindow*)windowHandle;
            [window toggleFullScreen:nil];
        };

        if (NSThread.isMainThread) {
            toggleBlock();
        } else {
            dispatch_async(dispatch_get_main_queue(), toggleBlock);
        }
#endif
    }
}
