local stubs = require("test.helpers.stub_koreader")
local restore_stubs = stubs.install()

local BookloreSync = require("main")
restore_stubs()

describe("BookloreSync CFI conversion", function()
  local plugin
  local doc

  before_each(function()
    plugin = setmetatable({}, { __index = BookloreSync })

    local files = {
      ["chapter1.xhtml"] = "<body><h2 id='h'>Title</h2><p id='p1'>One</p><p id='p2'>Two</p></body>",
      ["chapter2.xhtml"] = "<body><p>Another</p></body>",
    }

    doc = {
      getDocumentFileContent = function(_, href)
        return files[href]
      end,
    }
  end)

  it("converts xpointer paths to CFI steps", function()
    local steps = plugin:xpointerToCfiPath("/body/DocFragment[1]/body/p[2]/text().3", { "chapter1.xhtml" }, doc, {})
    assert.is_table(steps)
    assert.are.equal(2, steps.spine_step)
    assert.is_truthy(table.concat(steps):find(":3", 1, true))
  end)

  it("returns nil for out-of-range fragments", function()
    local steps = plugin:xpointerToCfiPath("/body/DocFragment[2]/body/p[1]/text().1", { "chapter1.xhtml" }, doc, {})
    assert.is_nil(steps)
  end)

  it("builds a ranged epubcfi expression", function()
    local cfi = plugin:buildCfi(
      "/body/DocFragment[1]/body/p[1]/text().1",
      "/body/DocFragment[1]/body/p[2]/text().2",
      { "chapter1.xhtml" },
      doc,
      {}
    )

    assert.is_string(cfi)
    assert.is_truthy(cfi:match("^epubcfi%(.+,.+,.+%)$"))
  end)
end)
