--[[--
Unit tests for CFI conversion helper functions.
Run with:  luajit test_cfi.lua
--]]--

local HTML_VOID_TAGS = {
    area=true, base=true, br=true, col=true, embed=true, hr=true,
    img=true, input=true, link=true, meta=true, param=true,
    source=true, track=true, wbr=true,
}

local function findNthElementOrdinal(html_content, element_name, nth)
    element_name = element_name:lower()
    local depth    = 0
    local ordinal  = 0
    local found    = 0

    local i = 1
    local len = #html_content
    while i <= len do
        local tag_start, tag_end, full_tag = html_content:find("(<[^>]+>)", i)
        if not tag_start then break end

        local is_closing      = full_tag:sub(1, 2) == "</"
        local is_self_closing = full_tag:sub(-2) == "/>"
        local tag_name = full_tag:match("^</?([%a][%w%-]*)")
        if tag_name then tag_name = tag_name:lower() end

        if is_closing then
            depth = depth - 1
        else
            local void = HTML_VOID_TAGS[tag_name] or false
            if depth == 0 then
                ordinal = ordinal + 1
                if tag_name == element_name then
                    found = found + 1
                    if found == nth then
                        local elem_id = full_tag:match('%sid=["\']([^"\']+)["\']')
                        return ordinal, elem_id
                    end
                end
            end
            if not void and not is_self_closing then
                depth = depth + 1
            end
        end

        i = tag_end + 1
    end
    return nil, nil
end

local function extractNthElementContent(html_content, element_name, nth)
    element_name = element_name:lower()
    local depth        = 0
    local found        = 0
    local in_target    = false
    local target_depth = nil
    local content_start = nil

    local i   = 1
    local len = #html_content
    while i <= len do
        local tag_start, tag_end, full_tag = html_content:find("(<[^>]+>)", i)
        if not tag_start then break end

        local is_closing      = full_tag:sub(1, 2) == "</"
        local is_self_closing = full_tag:sub(-2) == "/>"
        local tag_name = full_tag:match("^</?([%a][%w%-]*)")
        if tag_name then tag_name = tag_name:lower() end

        local void = HTML_VOID_TAGS[tag_name] or false

        if is_closing then
            depth = depth - 1
            if in_target and depth == target_depth then
                return html_content:sub(content_start, tag_start - 1)
            end
        else
            if depth == 0 and tag_name == element_name then
                found = found + 1
                if found == nth then
                    in_target     = true
                    target_depth  = depth
                    content_start = tag_end + 1
                end
            end
            if not void and not is_self_closing then
                depth = depth + 1
            end
        end

        i = tag_end + 1
    end
    return nil
end

local BookloreSync = {}
function BookloreSync:logWarn(...) end
function BookloreSync:logErr(...)  end
function BookloreSync:logInfo(...) end

function BookloreSync:xpointerToCfiPath(xpointer, spine, document, html_cache)
    if not xpointer or not spine or not document then return nil end
    html_cache = html_cache or {}

    local frag_idx_s, inner_path = xpointer:match("^/body/DocFragment%[(%d+)%](.*)")
    if not frag_idx_s then return nil end

    local frag_idx   = tonumber(frag_idx_s)
    local spine_step = frag_idx * 2

    if frag_idx < 1 or frag_idx > #spine then return nil end

    local href = spine[frag_idx]
    if not href then return nil end

    local html = html_cache[href]
    if not html then
        html = document:getDocumentFileContent(href)
        if not html then return nil end
        html_cache[href] = html
    end

    local parts = {}
    for part in inner_path:gmatch("[^/]+") do
        table.insert(parts, part)
    end

    local steps = {}
    local current_content = html

    for idx, part in ipairs(parts) do
        -- text().N → /1:N
        local offset_s = part:match("^text%(%)%.(%d+)$")
        if offset_s then
            table.insert(steps, "/1")
            table.insert(steps, ":" .. offset_s)
            break
        end

        -- text()[K].N → /(2K-1):N
        local k_s, offset2_s = part:match("^text%(%)%[(%d+)%]%.(%d+)$")
        if k_s then
            local k = tonumber(k_s)
            table.insert(steps, "/" .. (2 * k - 1))
            table.insert(steps, ":" .. offset2_s)
            break
        end

        -- element step
        local elem_name, elem_idx_s = part:match("^([%a][%w%-]*)%[(%d+)%]$")
        if not elem_name then
            elem_name  = part:match("^([%a][%w%-]*)$")
            elem_idx_s = "1"
        end
        if not elem_name then return nil end
        local elem_idx = tonumber(elem_idx_s)

        if elem_name:lower() == "body" and idx == 1 then
            table.insert(steps, "/4")
            local body_content = current_content:match("<[Bb][Oo][Dd][Yy][^>]*>(.*)</%s*[Bb][Oo][Dd][Yy]%s*>")
            current_content = body_content or ""
        else
            local ordinal, elem_id = findNthElementOrdinal(current_content, elem_name, elem_idx)
            if not ordinal then return nil end
            local step = "/" .. (ordinal * 2)
            if elem_id and elem_id ~= "" then
                step = step .. "[" .. elem_id .. "]"
            end
            table.insert(steps, step)
            local child_content = extractNthElementContent(current_content, elem_name, elem_idx)
            current_content = child_content or ""
        end
    end

    steps.spine_step = spine_step
    return steps
end

function BookloreSync:buildCfi(pos0, pos1, spine, document, html_cache)
    if not pos0 or not pos1 then return nil end
    if not spine or not document then return nil end
    html_cache = html_cache or {}

    local steps0 = self:xpointerToCfiPath(pos0, spine, document, html_cache)
    local steps1 = self:xpointerToCfiPath(pos1, spine, document, html_cache)
    if not steps0 or not steps1 then return nil end

    local function buildStepList(steps)
        local list = { "/6/" .. steps.spine_step .. "!" }
        for _, s in ipairs(steps) do table.insert(list, s) end
        return list
    end

    local list0 = buildStepList(steps0)
    local list1 = buildStepList(steps1)

    local shared_len = 0
    local min_len = math.min(#list0, #list1)
    for i = 1, min_len do
        if list0[i] == list1[i] then
            shared_len = i
        else
            break
        end
    end

    -- Offset steps (":N") and the text-node step immediately preceding them
    -- must never be part of the shared path.
    -- Case 1: the shared boundary itself is an offset step (":N")
    if shared_len > 0 and list0[shared_len]:sub(1,1) == ":" then
        shared_len = shared_len - 1
    end
    -- Case 2: the first diverging step is an offset (":N"), meaning the last
    -- shared step is the paired text-node step ("/1", "/3", …) — pull it out.
    local next_idx = shared_len + 1
    if shared_len > 0
        and list0[next_idx] and list0[next_idx]:sub(1,1) == ":"
        and list1[next_idx] and list1[next_idx]:sub(1,1) == ":"
    then
        shared_len = shared_len - 1
    end

    local shared_parts, rel0_parts, rel1_parts = {}, {}, {}
    for i = 1, shared_len       do table.insert(shared_parts, list0[i]) end
    for i = shared_len+1, #list0 do table.insert(rel0_parts,  list0[i]) end
    for i = shared_len+1, #list1 do table.insert(rel1_parts,  list1[i]) end

    local shared = table.concat(shared_parts)
    local rel0   = table.concat(rel0_parts)
    local rel1   = table.concat(rel1_parts)

    if rel0 == "" and rel1 == "" then
        return "epubcfi(" .. shared .. table.concat(steps0) .. ")"
    end

    return "epubcfi(" .. shared .. "," .. rel0 .. "," .. rel1 .. ")"
end

local pass, fail = 0, 0

local function check(label, got, expected)
    if got == expected then
        print("  PASS: " .. label)
        pass = pass + 1
    else
        print("  FAIL: " .. label)
        print("        expected: " .. tostring(expected))
        print("        got:      " .. tostring(got))
        fail = fail + 1
    end
end

print("\n=== findNthElementOrdinal ===")

local body1 = "<h2>Title</h2><p>one</p><p>two</p><p>three</p>"
local ord, id_
ord, id_ = findNthElementOrdinal(body1, "h2", 1)
check("h2 is ordinal 1",         ord, 1)
check("h2 has no id",            id_, nil)
ord = findNthElementOrdinal(body1, "p", 1)
check("1st p is ordinal 2",      ord, 2)
ord = findNthElementOrdinal(body1, "p", 2)
check("2nd p is ordinal 3",      ord, 3)
ord = findNthElementOrdinal(body1, "p", 3)
check("3rd p is ordinal 4",      ord, 4)
ord = findNthElementOrdinal(body1, "p", 4)
check("4th p (missing) → nil",   ord, nil)

-- ID assertion extraction
local body_id = '<div id="Copyright01"><p>text</p></div><p>out</p>'
ord, id_ = findNthElementOrdinal(body_id, "div", 1)
check("div with id: ordinal 1",  ord, 1)
check("div id = Copyright01",    id_, "Copyright01")
ord, id_ = findNthElementOrdinal(body_id, "p", 1)
check("outer p ordinal 2",       ord, 2)
check("outer p has no id",       id_, nil)

-- Nested content / void tags
local body2 = "<div><p>inner</p></div><p>sibling</p>"
check("outer p is ordinal 2",    findNthElementOrdinal(body2, "p", 1), 2)
check("inner p invisible",       findNthElementOrdinal(body2, "p", 2), nil)

local body3 = "<h2>A</h2><br/><p>B</p><p>C</p>"
check("br is ordinal 2 (void)",  findNthElementOrdinal(body3, "br", 1), 2)
check("p[1] after br is ord 3",  findNthElementOrdinal(body3, "p", 1),  3)

-- <br /> with space
local body4 = "<h2>A</h2><br /><p>B</p>"
check("br space: p[1] is ord 3", findNthElementOrdinal(body4, "p", 1), 3)

print("\n=== extractNthElementContent ===")

local body8 = "<h2>Title</h2><p>first</p><p>second</p><p>third</p>"
check("extract h2",              extractNthElementContent(body8, "h2", 1), "Title")
check("extract p[1]",            extractNthElementContent(body8, "p",  1), "first")
check("extract p[2]",            extractNthElementContent(body8, "p",  2), "second")
check("extract p[4] → nil",      extractNthElementContent(body8, "p",  4), nil)

local body9 = "<div><p>inner<b>bold</b></p></div><p>out</p>"
check("div nested preserved",    extractNthElementContent(body9, "div", 1), "<p>inner<b>bold</b></p>")

print("\n=== xpointerToCfiPath — text node step formats ===")

-- HTML: <html><head></head><body><h2>Ch</h2><p>First.</p><p>Second.</p></body></html>
local mini_html = "<html><head></head><body><h2>Ch</h2><p>First paragraph.</p><p>Second paragraph.</p></body></html>"
local fake_spine = { "OEBPS/ch1.xhtml" }
local fake_doc   = { getDocumentFileContent = function(self, _) return mini_html end }

local function cfiStepsToPath(steps)
    if not steps then return nil end
    return "/6/" .. steps.spine_step .. "!" .. table.concat(steps)
end

-- text().N → /1:N
local s = BookloreSync:xpointerToCfiPath(
    "/body/DocFragment[1]/body/h2/text().0", fake_spine, fake_doc, {})
check("h2/text().0 → /6/2!/4/2/1:0",   cfiStepsToPath(s), "/6/2!/4/2/1:0")

local s2 = BookloreSync:xpointerToCfiPath(
    "/body/DocFragment[1]/body/p[2]/text().5", fake_spine, fake_doc, {})
check("p[2]/text().5 → /6/2!/4/6/1:5", cfiStepsToPath(s2), "/6/2!/4/6/1:5")

-- text()[K].N → /(2K-1):N
-- text()[1].0 → /1:0  (K=1 → 2*1-1=1)
local s3 = BookloreSync:xpointerToCfiPath(
    "/body/DocFragment[1]/body/p[1]/text()[1].0", fake_spine, fake_doc, {})
check("text()[1].0 → /1:0 (K=1→step1)", cfiStepsToPath(s3), "/6/2!/4/4/1:0")

-- text()[2].92 → /3:92  (K=2 → 2*2-1=3)
local s4 = BookloreSync:xpointerToCfiPath(
    "/body/DocFragment[1]/body/p[1]/text()[2].92", fake_spine, fake_doc, {})
check("text()[2].92 → /3:92 (K=2→step3)", cfiStepsToPath(s4), "/6/2!/4/4/3:92")

print("\n=== xpointerToCfiPath — id assertions ===")

local html_id = '<html><head></head><body><div id="Copyright01"><p>text</p></div></body></html>'
local spine_id = { "OEBPS/copy.xhtml" }
local doc_id   = { getDocumentFileContent = function(self, _) return html_id end }

local s5 = BookloreSync:xpointerToCfiPath(
    "/body/DocFragment[1]/body/div/p/text().0", spine_id, doc_id, {})
-- body→/4, div[1] is ordinal 1 with id "Copyright01" → /2[Copyright01],
-- p[1] inside div is ordinal 1 → /2, text().0 → /1:0
check("div id assertion in path", cfiStepsToPath(s5), "/6/2!/4/2[Copyright01]/2/1:0")

print("\n=== buildCfi — range format ===")

-- Same spine item, same element, different text offsets → shared path is
-- everything up to and including the element step; rel parts are /1:N
local cfi_same = BookloreSync:buildCfi(
    "/body/DocFragment[1]/body/p[1]/text().0",
    "/body/DocFragment[1]/body/p[1]/text().29",
    fake_spine, fake_doc, {}
)
-- Shared through /6/2!/4/4, then rel0=/1:0, rel1=/1:29
check("same element range",
    cfi_same,
    "epubcfi(/6/2!/4/4,/1:0,/1:29)")

-- Same spine item, different paragraphs → shared through /6/2!/4, then
-- rel0=/4/1:0, rel1=/6/1:29
local cfi_diff = BookloreSync:buildCfi(
    "/body/DocFragment[1]/body/p[1]/text().0",
    "/body/DocFragment[1]/body/p[2]/text().29",
    fake_spine, fake_doc, {}
)
check("different elements range",
    cfi_diff,
    "epubcfi(/6/2!/4,/4/1:0,/6/1:29)")

-- Different spine items → shared only through /6/ (the "!" differs), so
-- both full paths appear as rel0 and rel1 with empty shared
local fake_spine2 = { "OEBPS/ch1.xhtml", "OEBPS/ch2.xhtml" }
local fake_doc2   = { getDocumentFileContent = function(self, _) return mini_html end }
local cfi_cross = BookloreSync:buildCfi(
    "/body/DocFragment[1]/body/p[1]/text().0",
    "/body/DocFragment[2]/body/p[1]/text().5",
    fake_spine2, fake_doc2, {}
)
-- list0[1]="/6/2!" vs list1[1]="/6/4!" → diverge immediately → shared=""
check("cross-spine range (no shared prefix)",
    cfi_cross,
    "epubcfi(,/6/2!/4/4/1:0,/6/4!/4/4/1:5)")

-- nil spine/document → nil
check("nil spine → nil", BookloreSync:buildCfi("a","b",nil,fake_doc,{}), nil)
check("nil document → nil", BookloreSync:buildCfi("a","b",fake_spine,nil,{}), nil)

print("\n=== Real xpointer patterns (metadata.epub.lua annotation [4]) ===")

-- annotation [4]: pos0 = "/body/DocFragment[11]/body/div/section/p[30]/text()[2].92"
--                 pos1 = "/body/DocFragment[11]/body/div/section/p[31]/text()[1].127"
--
-- We build a minimal HTML that matches the structure:
-- body > div > section > p[30] + p[31]
-- Build 31 <p> elements inside section, inside div, inside body.
local ps = {}
for i = 1, 31 do
    table.insert(ps, "<p>paragraph " .. i .. " text node 1<span>elem</span>text node 2</p>")
end
local real_html = "<html><head></head><body><div><section>" ..
    table.concat(ps) ..
    "</section></div></body></html>"

local real_spine = {}
for i = 1, 11 do real_spine[i] = "OEBPS/ch" .. i .. ".xhtml" end
local real_doc = { getDocumentFileContent = function(self, _) return real_html end }

-- For pos0: p[30]/text()[2].92 → text node K=2 → CFI step /(2*2-1)=3 → /3:92
-- For pos1: p[31]/text()[1].127 → text node K=1 → CFI step /1 → /1:127
-- Both in DocFragment[11] → spine_step = 22
-- body→/4, div[1]→/2, section[1]→/2, p[30]→ordinal 30→/60, p[31]→ordinal 31→/62

local r_steps0 = BookloreSync:xpointerToCfiPath(
    "/body/DocFragment[11]/body/div/section/p[30]/text()[2].92",
    real_spine, real_doc, {}
)
check("p[30]/text()[2].92 spine_step=22",  r_steps0 and r_steps0.spine_step, 22)
check("p[30]/text()[2].92 path ends /60/3:92",
    r_steps0 and cfiStepsToPath(r_steps0):match("/60/3:92$") ~= nil, true)

local r_steps1 = BookloreSync:xpointerToCfiPath(
    "/body/DocFragment[11]/body/div/section/p[31]/text()[1].127",
    real_spine, real_doc, {}
)
check("p[31]/text()[1].127 path ends /62/1:127",
    r_steps1 and cfiStepsToPath(r_steps1):match("/62/1:127$") ~= nil, true)

local r_cfi = BookloreSync:buildCfi(
    "/body/DocFragment[11]/body/div/section/p[30]/text()[2].92",
    "/body/DocFragment[11]/body/div/section/p[31]/text()[1].127",
    real_spine, real_doc, {}
)
-- Shared path up to (and including) /4/2/2 (body/div/section), then
-- rel0 = /60/3:92, rel1 = /62/1:127
check("cross-para CFI shared through section",
    r_cfi,
    "epubcfi(/6/22!/4/2/2,/60/3:92,/62/1:127)")

print(string.format("\n=== Results: %d passed, %d failed ===", pass, fail))
if fail > 0 then os.exit(1) end
