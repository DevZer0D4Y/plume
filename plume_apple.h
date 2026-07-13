//
// plume
//
// Copyright (c) 2024 renderbag and contributors. All rights reserved.
// Licensed under the MIT license. See LICENSE file for details.
//

#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <TargetConditionals.h>
#include "plume_render_interface_types.h"

namespace plume {
    RenderDeviceVendor getRenderDeviceVendor(uint64_t registryID);

#if TARGET_OS_IPHONE
    void* ensureMetalLayerForIOSWindow(void* window);
    void setMetalLayerDrawableCount(void* layer, uint32_t drawableCount);
#endif

    struct CocoaWindowAttributes {
        int x, y;
        int width, height;
    };

    struct CocoaWindowState {
        void* windowHandle;
        CocoaWindowAttributes cachedAttributes;
        std::atomic<int> cachedRefreshRate;
        mutable std::mutex attributesMutex;
        std::atomic<bool> attributesUpdatePending = false;
        std::atomic<bool> refreshRateUpdatePending = false;
        std::atomic<int64_t> nextAttributesUpdateNs = 0;
        std::atomic<int64_t> nextRefreshRateUpdateNs = 0;
    };

    class CocoaWindow {
        std::shared_ptr<CocoaWindowState> state;
        void updateWindowAttributesInternal(bool forceSync = false);
        void updateRefreshRateInternal(bool forceSync = false);
    public:
        CocoaWindow(void* window);
        ~CocoaWindow();

        // Get cached window attributes, may trigger async update
        void getWindowAttributes(CocoaWindowAttributes* attributes) const;

        // Get cached refresh rate, may trigger async update
        int getRefreshRate() const;

        // Toggle fullscreen
        void toggleFullscreen();
    };
}
