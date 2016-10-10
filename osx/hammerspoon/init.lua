-- Modeline {{{
-- vim: set foldmarker={{{,}}} foldlevel=1 foldmethod=marker
-- luacheck: globals hs ignore globals
-- }}}

-- Require {{{

local spaces = require("hs._asm.undocumented.spaces")
local secrets = require("secrets")

-- }}}

-- Constants / Definitions {{{

local mash = {"cmd", "alt", "ctrl"}
local mash_shift = {"cmd", "alt", "ctrl", "shift"}
local animationDuration = 0
local shadows = false

local wf = hs.window.filter

globals = {}
globals["WiFi"] = {}
globals["watcher"] = {}
globals["windows"] = {}
globals["hotkey"] = {}
globals["geeklets"] = {}
globals["wfilters"] = {}
globals["cycle"] = {}

local cardinals = { h="west", l="east", k="north", j="south", }
local snapped = {
    west=hs.geometry(0,0,0.5,1), east=hs.geometry(0.5,0,0.5,1),
    north=hs.geometry(0,0,1,0.5), south=hs.geometry(0,0.5,1,0.5),
}

-- }}}

-- Settings {{{

hs.window.animationDuration = animationDuration  -- Disable window animation
hs.window.setShadows(shadows)  -- No windows shadow
hs.window.filter.setLogLevel('nothing')  -- Disable window filter logging

-- }}}

-- Helpers {{{

-- Inspired by hs.fnutils.cycle
-- local function cycle(t)
--     local i = 1
--     return function(reverse)
--         if not reverse then i = i % #t + 1 else i = i ~= 1 and i - 1 or #t end
--         return t[i]
--     end
-- end

local function cleanup()
    -- Cleanup here.
    hs.fnutils.each(globals["hotkey"], function(h) h:disable() end)
    hs.fnutils.each(globals["watcher"], function(w) w:stop() end)
    hs.fnutils.each(globals["geeklets"]["timers"], function(t) t:stop() end)
    hs.fnutils.each(globals["geeklets"]["geeklets"], function(g) g:delete() end)
    hs.fnutils.each(globals["wfilters"], function(f) f:unsubscribeAll() end)

    globals["pushbullet"]:close()

    for key in pairs(globals) do globals[key] = nil end
    globals = nil
end

-- }}}

-- WiFi management {{{

globals["WiFi"]["SSIDs"] = {
    HackedStationWiFi='Casa TiPPi',
    colossus='University', sapienza='University',
    TNCAP448DE3='Casa Carpineto',
}
globals["WiFi"]["callbacks"] = {}
globals["WiFi"]["lastSSID"] = hs.wifi.currentNetwork()

local function ssidChangedCallback()
    local newSSID = hs.wifi.currentNetwork()

    if newSSID == nil and hs.wifi.interfaceDetails("en0")["power"] == true then
        hs.notify.new({
            title="Hammerspoon",
            informativeText="Wireless disconnected",
            contentImage=hs.image.imageFromPath("icons/internet.ico"),
            autoWithdraw=true
        }):send()
        return
    end

    if globals["WiFi"]["lastSSID"] == newSSID then return end

    local networkLocation = globals["WiFi"]["SSIDs"][newSSID]
    if networkLocation then
        if hs.applescript('do shell script "scselect \'' .. networkLocation .. '\'"') then
            hs.notify.new({
                title="Hammerspoon",
                contentImage=hs.image.imageFromPath("icons/internet.ico"),
                informativeText="Selecting '" .. networkLocation .. "' network location.",
                autoWithdraw=true
            }):send()
        else
            hs.notify.new({
                title="Hammerspoon",
                informativeText="Unknown error while managing network locations.",
                autoWithdraw=true
            }):send()
        end
    end

    local callback = globals["WiFi"]["callbacks"][networkLocation]
    if callback then assert(#callback == 2); callback[1]() end

    local lastSSID = globals["WiFi"]["lastSSID"]
    local lastNetworkLocation = globals["WiFi"]["SSIDs"][lastSSID]
    callback = globals["WiFi"]["callbacks"][lastNetworkLocation]
    if callback then assert(#callback == 2); callback[2]() end

    globals["WiFi"]["lastSSID"] = newSSID
end
globals["watcher"]["wifi"] = hs.wifi.watcher.new(ssidChangedCallback):start()

-- }}}

-- USB management {{{

local function usbDeviceCallback(data)
    if data["productID"] == 49944 and data["vendorID"] == 1133 then
        if (data["eventType"] == "added") then
            hs.keycodes.setLayout('Keyboard Illuminated IT')
        elseif (data["eventType"] == "removed") then
            hs.keycodes.setLayout('Italian')
        end
    end
end
globals["watcher"]["usb"] = hs.usb.watcher.new(usbDeviceCallback):start()

-- }}}

-- Spaces {{{

local function adjacentSpace(left)
    local layout = spaces.layout()[spaces.mainScreenUUID()]

    local current = hs.fnutils.indexOf(layout, spaces.activeSpace())
    assert(current ~= nil)

    local adjacent
    if not left then
        adjacent = current % #layout + 1
    else
        adjacent = current ~= 1 and current - 1 or #layout
    end

    return layout[adjacent], adjacent
end

local function toNextSpace(left)
    local space, index = adjacentSpace(left)
    hs.alert.closeAll()
    hs.alert.show("Desktop " .. index, 0.5)
    -- spaces.changeToSpace(space, false)  -- Do not reset dock
    spaces.changeToSpace(space, true)  -- Do not reset dock
    hs.window.frontmostWindow():focus()
end

local function moveToNextSpace(window, left)
    local newSpaceID = adjacentSpace(left)
    window:spacesMoveTo(newSpaceID)
    hs.window.frontmostWindow():focus()
end

-- }}}

-- Windows {{{

globals["windows"]["savedFrames"] = {}
local function setFrame(window, frame)
    assert(window)
    local windowID = window:id()
    assert(windowID)

    -- Check if window was snapped on one of the borders.
    local cardinal = hs.fnutils.indexOf(globals["windows"], windowID)
    if cardinal then globals["windows"][cardinal] = nil end

    local savedFrame = globals["windows"]["savedFrames"][windowID]
    if frame == nil and savedFrame == nil then return end  -- Nothing to do

    if frame == nil then
        assert(savedFrame)
        window:setFrame(savedFrame)  -- Restore the original frame
        globals["windows"]["savedFrames"][windowID] = nil
        return
    end

    if savedFrame == nil then
        -- Save the current frame.
        globals["windows"]["savedFrames"][windowID] = window:frame()
    end

    if frame and frame.x <= 1 and frame.y <= 1
        and frame.w <= 1 and frame.h <= 1 then
        window:moveToUnit(frame)
    else
        window:move(frame)
    end

    -- Store that window is snapped to one of the borders.
    cardinal = hs.fnutils.indexOf(snapped, frame)
    if cardinal then globals["windows"][cardinal] = windowID end
end

local function resize(window, enlarge)
    if not window then return end

    local frame = window:frame()
    assert(frame)

    if enlarge then
        frame.x = frame.x - (frame.w * 1 / 20)
        frame.y = frame.y - (frame.h * 1 / 20)

        frame.w = frame.w * 11 / 10
        frame.h = frame.h * 11 / 10

        if frame.x < 0 then frame.x = 0 end
        if frame.y < 0 then frame.y = 0 end

        local screen = window:screen():frame()
        if frame.w > screen.w then frame.w = screen.w end
        if frame.h > screen.h then frame.h = screen.h end
    else
        frame.x = frame.x + (frame.w * 1 / 20)
        frame.y = frame.y + (frame.h * 1 / 20)

        frame.w = frame.w * 9 / 10
        frame.h = frame.h * 9 / 10
    end

    setFrame(window, frame)
end

-- }}}

-- Window filters {{{

globals["wfilters"]["finder"] = wf.copy(wf.defaultCurrentSpace):setAppFilter('Finder')
globals["wfilters"]["finder"]:subscribe(
    wf.windowDestroyed,
    function(_, _, _)
        -- Focus last focused window as soon as a window is destroyed
        local lastFocused = wf.defaultCurrentSpace:getWindows(wf.sortByFocusedLast)
        if #lastFocused > 0 then lastFocused[1]:focus() end
    end
)

-- }}}

-- Bindings {{{

hs.hotkey.bind(mash, "r", function()
    cleanup()
    hs.reload()
    hs.notify.new({
        title="Hammerspoon",
        informativeText="Configuration reloaded",
        autoWithdraw=true
    }):send()
end)

hs.hotkey.bind(mash, "c", function()
    hs.toggleConsole()
    hs.window.frontmostWindow():focus()
end)

-- Quick open Downloads/Desktop
hs.fnutils.each({{"d", "Downloads"}, {"s", "Desktop"}}, function(k)
    hs.hotkey.bind(mash, k[1], function()
        hs.applescript('tell application "Finder"\n'
        .. 'open folder "' .. k[2] .. '" of home\nactivate\nend tell')
    end)
end)

-- Switch to space on left/right
hs.fnutils.each({{"right", false}, {"left", true}}, function(k)
    hs.hotkey.bind(mash, k[1], function()
        toNextSpace(k[2])
    end)
end)

-- Move window to space on left/right
hs.fnutils.each({{"right", false}, {"left", true}}, function(k)
    hs.hotkey.bind(mash_shift, k[1], function()
        local focused = hs.window.focusedWindow()
        if focused then moveToNextSpace(focused, k[2]) end
    end)
end)

-- Fullscreen / revert to original
hs.fnutils.each({{"delete", nil}, {"return", hs.geometry(0,0,1,1)}}, function(k)
    hs.hotkey.bind(mash, k[1], function()
        local focused = hs.window.focusedWindow()
        if focused then setFrame(focused, k[2]) end
    end)
end)

-- Snap west, south, north, east
hs.fnutils.each({"h", "j", "k", "l"}, function(k)
    hs.hotkey.bind(mash_shift, k, function()
        local focused = hs.window.focusedWindow()
        if focused then setFrame(focused, snapped[cardinals[k]]) end
    end)
end)

-- Focus window on west, south, north, east
hs.fnutils.each({"h", "j", "k", "l"}, function(k)
    hs.hotkey.bind(mash, k, function()
        local snappedID = globals["windows"][cardinals[k]]
        if snappedID then hs.window.get(snappedID):focus(); return end

        local f = "focusWindow" .. cardinals[k]:gsub("^%l", string.upper)
        wf.defaultCurrentSpace[f](wf.defaultCurrentSpace,
            nil, false, false
        )
    end)
end)

-- Focus second-last window
hs.hotkey.bind(mash, "space", function()
    local lastFocused = wf.defaultCurrentSpace:getWindows(wf.sortByFocusedLast)
    if #lastFocused > 1 then lastFocused[2]:focus() end
end)

-- Center on screen
hs.hotkey.bind(mash, ".", function()
    local focused = hs.window.focusedWindow()
    if focused then focused:centerOnScreen() end
end)

-- Enlarge / shrink window
hs.fnutils.each({{"-", false}, {"+", true}}, function(k)
    hs.hotkey.bind(mash, k[1], function()
        resize(hs.window.focusedWindow(), k[2])
    end)
end)

-- }}}

-- iTerm2 {{{

-- Launch iTerm2 by pressing alt-space
globals["hotkey"]["iTerm"] = hs.hotkey.new({"alt"}, "space", function()
    hs.application.open("com.googlecode.iterm2")
end)

-- Enable the hotkey if iTerm2 is not running
if not hs.application.find("iTerm") then
    globals["hotkey"]["iTerm"]:enable()
end

-- Then enable/disable it as needed
globals["watcher"]["app"] = hs.application.watcher.new(function(appName, event, _)
    if appName == "iTerm2" then
        if event == hs.application.watcher.launching then
            globals["hotkey"]["iTerm"]:disable()
        elseif
        event == hs.application.watcher.terminated then
            globals["hotkey"]["iTerm"]:enable()
        end
    end
end):start()

-- }}}

-- Drawing {{{

local geekletsTextStyle = {
    font={name='Futura', size=22},
    strokeColor=hs.drawing.color.asRGB({red=0, green=0, blue=0, alpha=1}),
    strokeWidth=-1.0,
    paragraphStyle={alignment='center', }
}

globals["geeklets"]["geeklets"] = {}  -- Holds geeklets for future updates.
globals["geeklets"]["timers"] = {}  -- Hold timers updating the geeklets

local function drawTimeGeeklet(r)
    local geeklets = globals["geeklets"]["geeklets"]
    local timeString = hs.styledtext.new(os.date("%H:%M"), geekletsTextStyle)
    local time = geeklets['time']
    if time == nil then
        time = hs.drawing.text(r, timeString)
        geeklets['time'] = time
        assert(geeklets['time'])
        time:show()
    else
        time:setStyledText(timeString)
    end
end

local function drawSpotifyInfoGeeklet(r)
    local geeklets = globals["geeklets"]["geeklets"]
    local empty = hs.styledtext.new("", geekletsTextStyle)
    local spotify = geeklets['spotify']
    if spotify == nil then
        spotify = hs.drawing.text(hs.geometry.rect(r), empty)
        geeklets['spotify'] = spotify
        spotify:show()
    end
    assert(spotify)

    if hs.spotify.isRunning() then
        local track = hs.spotify.getCurrentTrack()
        local album = hs.spotify.getCurrentAlbum()
        local artist = hs.spotify.getCurrentArtist()

        if not track or not album or not artist then
            return
        end

        spotify:setStyledText(hs.styledtext.new(
            track .. " | " .. album .. " | " .. artist, geekletsTextStyle
        ))
    else
        spotify:setStyledText(empty)
    end
end

local function drawBatteryGeeklet(r)
    local geeklets = globals["geeklets"]["geeklets"]
    local batteryPercentage = hs.styledtext.new(math.floor(hs.battery.percentage()) .. "%", geekletsTextStyle)
    local battery = geeklets['battery']
    if battery == nil then
        battery = hs.drawing.text(r, batteryPercentage)
        geeklets['battery'] = battery
        battery:show()
    else
        battery:setStyledText(batteryPercentage)
    end
end

local function drawTopGeeklets()
    local geeklets = globals["geeklets"]["geeklets"]
    local height = 50
    local textVOffset = (height - geekletsTextStyle['font']['size'] * 1.33)
    local frame = hs.screen.primaryScreen():frame()

    local top_background = hs.drawing.rectangle(hs.geometry.rect(0, 10, frame.w, height))
    geeklets['top_bg'] = top_background
    top_background:setStroke(false)
    top_background:setFillColor(hs.drawing.color.asRGB({red=0, green=0, blue=0, alpha=0.4}))
    top_background:setLevel(hs.drawing.windowLevels['desktop'])
    top_background:setBehaviorByLabels({'stationary'})
    top_background:show()

    local timeRect = hs.geometry.rect(0, textVOffset, frame.w / 4, height / 3 * 2)
    drawTimeGeeklet(timeRect)
    local spotifyRect = hs.geometry.rect(frame.w / 4, textVOffset, frame.w / 2, height / 3 * 2)
    drawSpotifyInfoGeeklet(spotifyRect)
    local batteryRect = hs.geometry.rect(frame.w * 3 / 4, textVOffset, frame.w / 4, height / 3 * 2)
    drawBatteryGeeklet(batteryRect)

    for _, geeklet in pairs(geeklets) do
        geeklet:setLevel(hs.drawing.windowLevels['desktop'])
        geeklet:setBehaviorByLabels({'stationary'})
    end

    local timers = globals["geeklets"]["timers"]
    timers['time'] = hs.timer.doEvery(10, function() drawTimeGeeklet(timeRect) end)
    timers['spotify'] = hs.timer.doEvery(5, function() drawSpotifyInfoGeeklet(spotifyRect) end)
    timers['battery'] = hs.timer.doEvery(120, function() drawBatteryGeeklet(batteryRect) end)
end
drawTopGeeklets()

globals["watcher"]["screen"] = hs.screen.watcher.new(function()
    local timers = globals["geeklets"]["timers"]
    local geeklets = globals["geeklets"]["geeklets"]

    for _, timer in pairs(timers) do timer:stop() end
    globals["geeklets"]["timers"] = {}

    for _, geeklet in pairs(geeklets) do geeklet:hide() end
    globals["geeklets"]["geeklets"] = {}

    drawTopGeeklets()
end)
globals["watcher"]["screen"]:start()

-- }}}

-- Pushbullet {{{

local pb_api_key = secrets.PUSHBULLET_API_KEY

hs.notify.register('pb', function()
    hs.http.asyncGet('https://api.pushbullet.com/v2/pushes?limit=1',
    {["Access-Token"]=pb_api_key},
    function(status, body, _)
        if not status or status > 200 then
            print("Error (" .. status .. ") while getting pushes.")
            return
        end

        local pushes = hs.json.decode(body)
        local push = pushes.pushes[1]
        if not push.dismissed then
            assert(push.iden)
            hs.http.asyncPost(
                'https://api.pushbullet.com/v2/pushes/' .. push.iden,
                hs.json.encode({dismissed=true}),
                {["Access-Token"]=pb_api_key, ["Content-Type"]='application/json'},
                function(postStatus, _, _)
                    if not postStatus or postStatus > 200 then
                        print("Error (" .. postStatus .. ") while marking push as read")
                    end
                end
            )
        end
    end)
end)

local function pushbullet()
    return hs.http.websocket('wss://stream.pushbullet.com/websocket/' .. pb_api_key,
    function(ws_body)
        local alert = hs.json.decode(ws_body)
        if alert['type'] == 'nop' then return end
        hs.http.asyncGet('https://api.pushbullet.com/v2/pushes?limit=1',
        {["Access-Token"]=pb_api_key},
        function(status, body, _)
            if not status or status > 200 then
                print("Error (" .. status .. ") while getting pushes.")
                return
            end

            local pushes = hs.json.decode(body)
            local push = pushes.pushes[1]
            if not push or not push.dismissed or push.body then return end

            hs.pasteboard.setContents(push.body)
            hs.notify.new('pb', {
                title=push.title or "Pushbullet",
                informativeText=push.body, autoWithdraw=true,
                contentImage=hs.image.imageFromPath('icons/pushbullet.ico')
            }):send()
        end)
    end)
end
globals["pushbullet"] = pushbullet()

-- }}}

-- Reachability {{{

globals["watcher"]["internet"] = hs.network.reachability.internet():setCallback(
function(_, flags)
    if flags == hs.network.reachability.flags.reachable then
        -- A default route exists, so an active internet connection is present
        print("Active internet connection found.")
        globals["pushbullet"]:close()
        globals["pushbullet"] = pushbullet()
    else
        -- No default route exists, so no active internet connection is present
        print("Internet connectivity lost.")
        globals["pushbullet"]:close()
    end
end):start()

-- }}}