-- Cached setters: Windower's images/texts setters always call into the C API (texts:pos even
-- reads the windower settings), so only call them when a value changes.
-- Never mix these with direct obj:pos()/obj:show() calls on the same object.
local images = require('images')
local texts = require('texts')

local M = {}

local cache = setmetatable({}, {__mode = 'k'})

local function st(o)
    local c = cache[o]
    if not c then
        c = {}
        cache[o] = c
    end
    return c
end

function M.pos(o, x, y)
    local c = st(o)
    if c.x ~= x or c.y ~= y then
        o:pos(x, y)
        c.x, c.y = x, y
    end
end

function M.size(o, w, h)
    local c = st(o)
    if c.w ~= w or c.h ~= h then
        o:size(w, h)
        c.w, c.h = w, h
    end
end

function M.path(o, path)
    local c = st(o)
    if c.path ~= path then
        o:path(path)
        c.path = path
    end
end

function M.color(o, r, g, b)
    local c = st(o)
    if c.r ~= r or c.g ~= g or c.b ~= b then
        o:color(r, g, b)
        c.r, c.g, c.b = r, g, b
    end
end

function M.alpha(o, a)
    local c = st(o)
    if c.a ~= a then
        o:alpha(a)
        c.a = a
    end
end

function M.show(o)
    local c = st(o)
    if c.vis ~= true then
        o:show()
        c.vis = true
    end
end

function M.hide(o)
    local c = st(o)
    if c.vis ~= false then
        o:hide()
        c.vis = false
    end
end

function M.text(o, str)
    local c = st(o)
    if c.text ~= str then
        o:text(str)
        c.text = str
        -- Extents can lag a frame behind a text change; re-measure a few times.
        c.ext_left = 3
    end
end

function M.extents(o)
    local c = st(o)
    if c.ew == nil or (c.ext_left or 0) > 0 then
        c.ew, c.eh = o:extents()
        c.ext_left = math.max(0, (c.ext_left or 0) - 1)
    end
    return c.ew, c.eh
end

-- texts:size is the font size.
function M.fsize(o, n)
    local c = st(o)
    if c.fs ~= n then
        o:size(n)
        c.fs = n
        c.ext_left = 3
    end
end

-- Last position we drew (to detect user drags).
function M.last_pos(o)
    local c = st(o)
    return c.x, c.y
end

-- Resync after the user dragged the primitive.
function M.forget_pos(o)
    local c = st(o)
    c.x, c.y = nil, nil
end

local ui_root = (windower.addon_path or '') .. 'images/ui/'
M.ui_root = ui_root

function M.image(path)
    local im = images.new()
    im:draggable(false)
    im:fit(false)
    if path then
        im:path(path)
        st(im).path = path
    end
    im:hide()
    st(im).vis = false
    return im
end

function M.label(size, rgb, font, bold)
    local t = texts.new('', {
        pos = {x = 0, y = 0},
        text = {
            font = font or 'Consolas', size = size or 10, alpha = 255,
            red = rgb and rgb[1] or 235, green = rgb and rgb[2] or 235, blue = rgb and rgb[3] or 235,
            stroke = {width = 2, alpha = 200, red = 0, green = 0, blue = 0},
        },
        bg = {visible = false},
        flags = {bold = bold ~= false, right = false, draggable = false},
    })
    t:hide()
    st(t).vis = false
    return t
end

local PANEL_C = 12 -- corner size in images/ui/panel_*.png
local slices = {'tl', 't', 'tr', 'l', 'c', 'r', 'bl', 'b', 'br'}

function M.panel()
    local p = {}
    for _, k in ipairs(slices) do
        p[k] = M.image(ui_root .. 'panel_' .. k .. '.png')
    end
    return p
end

-- corner: on-screen corner size, so the frame scales with the widget.
function M.panel_layout(p, x, y, w, h, alpha, corner)
    local c = corner or PANEL_C
    w = math.max(w, c * 2 + 1)
    h = math.max(h, c * 2 + 1)
    local iw, ih = w - c * 2, h - c * 2
    local geo = {
        tl = {x, y, c, c}, t = {x + c, y, iw, c}, tr = {x + w - c, y, c, c},
        l = {x, y + c, c, ih}, c = {x + c, y + c, iw, ih}, r = {x + w - c, y + c, c, ih},
        bl = {x, y + h - c, c, c}, b = {x + c, y + h - c, iw, c}, br = {x + w - c, y + h - c, c, c},
    }
    for _, k in ipairs(slices) do
        local g, im = geo[k], p[k]
        M.pos(im, g[1], g[2])
        M.size(im, g[3], g[4])
        M.alpha(im, alpha or 255)
        M.show(im)
    end
end

function M.panel_hide(p)
    for _, k in ipairs(slices) do
        M.hide(p[k])
    end
end

function M.panel_destroy(p)
    for _, k in ipairs(slices) do
        pcall(function() p[k]:destroy() end)
    end
end

-- The centre slice is the drag handle.
function M.panel_handle(p)
    local x = st(p.c).x
    local tlx = st(p.tl).x
    return p.c, (x and tlx) and (x - tlx) or PANEL_C
end

function M.rect(r, g, b, a)
    local im = M.image(nil)
    M.color(im, r, g, b)
    M.alpha(im, a or 255)
    return im
end

function M.inside(mx, my, x, y, w, h)
    return mx and my and mx >= x and mx <= x + w and my >= y and my <= y + h
end

return M
