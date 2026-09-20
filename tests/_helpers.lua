-- Shared helpers for Reading Atlas's pure-Lua suites. Run by tests/run.sh
-- under a standalone `lua`, NOT inside KOReader. Named with a leading
-- underscore and no _test_ prefix, so run.sh's glob skips it.
local M = {}

function M.runner()
    local pass, fail = 0, 0
    local t = {}
    t.test = function(name, fn)
        local ok, err = pcall(fn)
        if ok then
            pass = pass + 1
        else
            fail = fail + 1
            io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n")
        end
    end
    t.done = function()
        io.stdout:write(("PASS %d  FAIL %d\n"):format(pass, fail))
        os.exit(fail == 0 and 0 or 1)
    end
    return t
end

-- Deep-enough equality for the tables these suites compare (numbers, strings,
-- and flat/nested tables of them). Reports the path to the first difference,
-- because "tables differ" is useless when the table has 365 keys.
function M.eq(got, want, msg)
    local function cmp(a, b, path)
        if type(a) ~= type(b) then
            error(("%s: at %s got %s, want %s"):format(
                msg or "eq", path, type(a), type(b)), 0)
        end
        if type(a) ~= "table" then
            if a ~= b then
                error(("%s: at %s got %s, want %s"):format(
                    msg or "eq", path, tostring(a), tostring(b)), 0)
            end
            return
        end
        for k, v in pairs(a) do cmp(v, b[k], path .. "." .. tostring(k)) end
        for k in pairs(b) do
            if a[k] == nil then
                error(("%s: at %s.%s missing in got"):format(
                    msg or "eq", path, tostring(k)), 0)
            end
        end
    end
    cmp(got, want, "")
end

return M
