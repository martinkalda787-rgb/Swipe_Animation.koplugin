-- User patch to enable page turn animation for PDFs/CBZs in KOReader paged mode
local ReaderPaging = require("apps/reader/modules/readerpaging")
local ReaderRolling = require("apps/reader/modules/readerrolling")
local Device = require("device")
local Event = require("ui/event")

-- Hook ReaderPaging:_gotoPage to dispatch PageChangeAnimation for PDFs/CBZs in paged mode
local original_gotoPage = ReaderPaging._gotoPage
function ReaderPaging:_gotoPage(number, orig_mode)
    if self.current_page and self.current_page > 0 and number ~= self.current_page and orig_mode ~= "scrolling" then
        if not G_reader_settings:isTrue("swipe_animations") then
            G_reader_settings:saveSetting("swipe_animations", true)
        end
        local forward = number > self.current_page
        self.ui:handleEvent(Event:new("PageChangeAnimation", forward))
    end
    return original_gotoPage(self, number, orig_mode)
end

-- Define onPageChangeAnimation for ReaderPaging so it handles the event
function ReaderPaging:onPageChangeAnimation(forward)
    local Screen = Device.screen
    if Screen then
        Screen:setSwipeAnimations(true)
        Screen:setSwipeDirection(forward)
    end
end

-- Define onPageChangeAnimation for ReaderRolling so it handles the event
function ReaderRolling:onPageChangeAnimation(forward)
    local Screen = Device.screen
    if Screen then
        Screen:setSwipeAnimations(true)
        Screen:setSwipeDirection(forward)
    end
end
