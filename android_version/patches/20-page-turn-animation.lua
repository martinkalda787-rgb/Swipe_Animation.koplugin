-- patches/20-page-turn-animation.lua
-- KOReader user patch: Enables optimized page turn sliding animation.
-- Contains a self-diagnostic error handler to display exact Lua errors on the device screen.

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")

-- ============================================================
-- 动画参数设置 (可根据你的墨水屏刷新模式进行微调)
-- ============================================================
local steps = 10       -- 动画帧数 (已设定为不低于 10 帧)
local delay_us = 0     -- 每帧延迟微秒 (已设为 0，以获得墨水屏允许的极限翻页速度)

local ok, err = pcall(function()
    local Device = require("device")
    local ffi = require("ffi")
    local logger = require("logger")
    local _ = require("gettext")

    logger.info("20-page-turn-animation: patch file loaded!")

    -- ============================================================
    -- Part 1: Force enable swipe animation capability
    -- ============================================================
    Device.canDoSwipeAnimation = function(self)
        logger.info("20-page-turn-animation: canDoSwipeAnimation called! returning true")
        return true
    end

    -- ============================================================
    -- Part 2: Patch Screen object immediately
    -- ============================================================
    local Screen = Device.screen
    if Screen then
        logger.info("20-page-turn-animation: Patching Screen methods")

        -- Add setSwipeAnimations
        Screen.setSwipeAnimations = function(self_screen, enabled)
            logger.info("20-page-turn-animation: setSwipeAnimations called with: " .. tostring(enabled))
            self_screen.swipe_animations = enabled
        end

        -- Add setSwipeDirection
        Screen.setSwipeDirection = function(self_screen, direction)
            logger.info("20-page-turn-animation: setSwipeDirection called with: " .. tostring(direction))
            self_screen.swipe_forward = direction
        end

        if Screen.swipe_animations == nil then
            Screen.swipe_animations = false
        end

        -- Override beforePaint to save the old page buffer when animation is armed, preserving native logic
        local original_beforePaint = Screen.beforePaint
        Screen.beforePaint = function(self_screen)
            local was_painting = self_screen.painting
            if original_beforePaint then
                original_beforePaint(self_screen)
            end
            if not was_painting and self_screen.swipe_animations then
                logger.info("20-page-turn-animation: beforePaint called, swipe_animations is true! Saving screen buffer.")
                if self_screen.saved_bb then self_screen.saved_bb:free() end
                self_screen.saved_bb = self_screen.bb:copy()
            end
        end
    else
        logger.warn("20-page-turn-animation: Screen is not available at patch load time!")
    end

    -- ============================================================
    -- Part 3: Patch page_turns menu immediately
    -- ============================================================
    local ok_menu, PageTurns = pcall(require, "ui/elements/page_turns")
    if ok_menu and PageTurns and PageTurns.sub_item_table then
        logger.info("20-page-turn-animation: Patching page_turns menu items")
        local has_anim_option = false
        for i, item in ipairs(PageTurns.sub_item_table) do
            if item.text == _("Page turn animations") or item.text == "Page turn animations" then
                has_anim_option = true
                item.sub_item_table = nil
                item.checked_func = function()
                    return G_reader_settings:isTrue("swipe_animations")
                end
                item.callback = function()
                    G_reader_settings:flipNilOrFalse("swipe_animations")
                end
                break
            end
        end

        if not has_anim_option then
            table.insert(PageTurns.sub_item_table, {
                text = _("Page turn animations"),
                checked_func = function()
                    return G_reader_settings:isTrue("swipe_animations")
                end,
                callback = function()
                    G_reader_settings:flipNilOrFalse("swipe_animations")
                end,
            })
        end
    else
        logger.warn("20-page-turn-animation: Failed to load ui/elements/page_turns!")
    end

    -- ============================================================
    -- Part 4: Refresh method wrappers
    -- ============================================================
    local refresh_methods = {
        a2 = function(screen, x, y, w, h, d) return screen:refreshA2(x, y, w, h, d) end,
        fast = function(screen, x, y, w, h, d) return screen:refreshFast(x, y, w, h, d) end,
        ui = function(screen, x, y, w, h, d) return screen:refreshUI(x, y, w, h, d) end,
        partial = function(screen, x, y, w, h, d) return screen:refreshPartial(x, y, w, h, d) end,
        ["[ui]"] = function(screen, x, y, w, h, d) return screen:refreshNoMergeUI(x, y, w, h, d) end,
        ["[partial]"] = function(screen, x, y, w, h, d) return screen:refreshNoMergePartial(x, y, w, h, d) end,
        flashui = function(screen, x, y, w, h, d) return screen:refreshFlashUI(x, y, w, h, d) end,
        flashpartial = function(screen, x, y, w, h, d) return screen:refreshFlashPartial(x, y, w, h, d) end,
        full = function(screen, x, y, w, h, d) return screen:refreshFull(x, y, w, h, d) end,
    }

    local function update_dither(dither1, dither2)
        if dither1 and not dither2 then
            return dither1
        else
            return dither2
        end
    end

    -- ============================================================
    -- Part 5: Override _repaint with animation support
    -- ============================================================
    UIManager._repaint = function(self)
        local Screen = Device.screen
        local dirty = false
        local dithered = false

        local start_idx = 1
        for i = #self._window_stack, 1, -1 do
            if self._window_stack[i].widget.covers_fullscreen then
                start_idx = i
                break
            end
        end

        for i = start_idx, #self._window_stack do
            local window = self._window_stack[i]
            local widget = window.widget
            if dirty or self._dirty[widget] then
                Screen:beforePaint()
                widget:paintTo(Screen.bb, window.x, window.y, self._dirty[widget])
                self._dirty[widget] = nil
                dirty = true
                if widget.dithered then
                    dithered = true
                end
            end
        end

        for _, refreshfunc in ipairs(self._refresh_func_stack) do
            local refreshtype, region, dither = refreshfunc()
            dither = update_dither(dither, dithered)
            if refreshtype then
                self:_refresh(refreshtype, region, dither)
            end
        end
        self._refresh_func_stack = {}

        if dirty and not self._refresh_stack[1] then
            self:_refresh("partial")
        end

        local software_animate = false
        if Screen.swipe_animations then
            local is_mtk = Screen.device and Screen.device.isMTK and Screen.device:isMTK()
            if not is_mtk then
                software_animate = true
                logger.info("20-page-turn-animation: _repaint entering animation block! swipe_animations is true.")
            else
                logger.info("20-page-turn-animation: _repaint skipped animation because is_mtk is true.")
            end
        else
            if dirty then
                logger.info("20-page-turn-animation: _repaint called, but Screen.swipe_animations is false.")
            end
        end

        if software_animate then
            Screen.swipe_animations = false
            self.refresh_counted = true

            local saved_bb = Screen.saved_bb
            Screen.saved_bb = nil
            if saved_bb then
                local new_bb = Screen.bb:copy()

                local screen_w = Screen.bb:getWidth()
                local screen_h = Screen.bb:getHeight()
                local swipe_forward = Screen.swipe_forward
                local prev_dx = 0

                logger.info("20-page-turn-animation: Playing animation loop. Steps: " .. tostring(steps) .. ", Direction: " .. tostring(swipe_forward))

                for i = 1, steps do
                    local progress = i / steps
                    local dx = i == steps and screen_w or (math.floor((screen_w * progress) / 16) * 16)
                    local strip_w = dx - prev_dx

                    if dx > prev_dx then
                        if swipe_forward then
                            Screen.bb:blitFrom(saved_bb, 0, 0, 0, 0, screen_w - dx, screen_h)
                            Screen.bb:blitFrom(new_bb, screen_w - dx, 0, screen_w - dx, 0, dx, screen_h)

                            if strip_w > 0 then
                                Screen:refreshPartial(screen_w - dx, 0, strip_w, screen_h)
                            end
                        else
                            Screen.bb:blitFrom(new_bb, 0, 0, 0, 0, dx, screen_h)
                            Screen.bb:blitFrom(saved_bb, dx, 0, dx, 0, screen_w - dx, screen_h)

                            if strip_w > 0 then
                                Screen:refreshPartial(prev_dx, 0, strip_w, screen_h)
                            end
                        end

                        prev_dx = dx

                        -- On non-eink platforms (Android/SDL), flush each frame to the display
                        if Device:isAndroid() or Device:isSDL() then
                            if swipe_forward then
                                Screen:refreshPartial(screen_w - dx, 0, strip_w, screen_h)
                            else
                                Screen:refreshPartial(prev_dx, 0, strip_w, screen_h)
                            end
                            Screen:afterPaint()
                            Screen:beforePaint()
                        end
                    end

                    if delay_us > 0 and ffi and ffi.C and ffi.C.usleep then
                        ffi.C.usleep(delay_us)
                    end
                end

                if self.FULL_REFRESH_COUNT and self.FULL_REFRESH_COUNT > 0 then
                    if not self._swipe_full_refresh_count then
                        self._swipe_full_refresh_count = 0
                    end

                    self._swipe_full_refresh_count = self._swipe_full_refresh_count + 1

                    if self._swipe_full_refresh_count >= self.FULL_REFRESH_COUNT then
                        Screen:refreshFull(0, 0, screen_w, screen_h)
                        self._swipe_full_refresh_count = 0
                    end
                end

                self._refresh_stack = {}
                new_bb:free()
                saved_bb:free()
            else
                logger.warn("20-page-turn-animation: software_animate is true but saved_bb is nil!")
            end
        end

        for _, refresh in ipairs(self._refresh_stack) do
            refresh.dither = update_dither(refresh.dither, dithered)
            if not Screen.hw_dithering then
                refresh.dither = nil
            end
            refresh_methods[refresh.mode](Screen,
                refresh.region.x, refresh.region.y,
                refresh.region.w, refresh.region.h,
                refresh.dither)
        end

        if dirty then
            Screen:afterPaint()
        end

        self._refresh_stack = {}
        self.refresh_counted = false
    end

    logger.info("20-page-turn-animation: patch applied successfully")
end)

if not ok then
    -- Show the exact error stack trace in a popup on the device screen
    UIManager:show(InfoMessage:new{text = "Patch error details:\n" .. tostring(err)})
    error(err)
end
