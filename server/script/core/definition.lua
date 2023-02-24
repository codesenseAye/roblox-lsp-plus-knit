local guide      = require 'core.guide'
local files      = require 'files'
local vm         = require 'vm'
local findSource = require 'core.find-source'

local function sortResults(results)
    -- 先按照顺序排序
    table.sort(results, function (a, b)
        local u1 = guide.getUri(a.target)
        local u2 = guide.getUri(b.target)
        if u1 == u2 then
            return a.target.start < b.target.start
        else
            return u1 < u2
        end
    end)
    -- 如果2个结果处于嵌套状态，则取范围小的那个
    local lf, lu
    for i = #results, 1, -1 do
        local res  = results[i].target
        local f    = res.finish
        local uri = guide.getUri(res)
        if lf and f > lf and uri == lu then
            table.remove(results, i)
        else
            lu = uri
            lf = f
        end
    end
end

local accept = {
    ['local']       = true,
    ['setlocal']    = true,
    ['getlocal']    = true,
    ['field']       = true,
    ['method']      = true,
    ['setglobal']   = true,
    ['getglobal']   = true,
    ['string']      = true,
    ['boolean']     = true,
    ['number']      = true,
    ['...']         = true,

    ['doc.type.name']    = true,
    ['doc.class.name']   = true,
    ['doc.extends.name'] = true,
    ['doc.alias.name']   = true,
    ['doc.see.name']     = true,
    ['doc.see.field']    = true,

    ['type.name']   = true
}

local function convertIndex(source)
    if not source then
        return
    end
    if source.type == 'string'
    or source.type == 'boolean'
    or source.type == 'number' then
        local parent = source.parent
        if not parent then
            return
        end
        if parent.type == 'setindex'
        or parent.type == 'getindex'
        or parent.type == 'tableindex' then
            return parent
        end
    end
    return source
end

return function (uri, offset)
    local ast = files.getAst(uri)
    if not ast then
        return nil
    end

    log.info("CALLED")

    local source = convertIndex(findSource(ast, offset, accept))
    if not source then
        return nil
    end

    local results = {}

    local defs = vm.getDefs(source, 0, {skipType = true})
    if source.type == "type.name" then
        defs[#defs+1] = source.typeAliasGeneric or vm.getTypeAlias(source)
    end

    -- KNIT METHOD GO-TO
    -- find the knit module method and replace the source with its proper source
    if source.type == "method" then
        local methodName = source[1]
        local tableName = source.parent and source.parent.parent and source.parent.parent.args and source.parent.parent.args[1]
        
        if tableName then

            if not tableName[1] then
                -- now this is probably .Client:MethodName()

                if tableName.field and tableName.field[1] == "Client" then
                    -- for sure now
                    tableName = tableName.field.parent.node[1]
                    -- this is the name of the knit module
                end
            else
                -- not .Client:MethodName()
                tableName = tableName[1]
            end

            if type(tableName) == "string" then

                -- log.tableInfo(source)
                local knitModuleUri

                for _, thisUri in ipairs(files.getAllUris()) do
                    if thisUri:find(tableName) then
                        knitModuleUri = thisUri
                            
                        if thisUri:find("init%.lua") then
                            -- if this was a init.lua file under a folder, this would be where the real methods are located
                            -- so stop here and make sure nothing overwrites it
                            log.info("HOVER STOP FULL STOP")
                            break
                        end
                    end
                end

                if knitModuleUri then
                    local uriAst = files.getAst(knitModuleUri)
                    local knitModuleText = files.getText(knitModuleUri)

                    if tableName and (tableName:find("Controller") or tableName:find("Service")) then
                        guide.eachSourceType(uriAst.ast, "setmethod", function(src)
                            local textInRange = knitModuleText:sub(src.start, src.finish)
                            textInRange = textInRange:sub(textInRange:find(":") + 1, -1)                
                        
                            if textInRange == methodName then
                                table.insert(defs, src)
                                --source = src
                            end
                        end)
                    end
                else
                    -- failed to find the knit module uri to get the hover method
                end
            else
                -- the result was a table so its not a knit module call
            end
        end
    end


    local values = {}
    for _, src in ipairs(defs) do
        local value = guide.getObjectValue(src)
        if value and value ~= src then
            values[value] = true
        end
    end
    for _, src in ipairs(defs) do
        if src.dummy then
            goto CONTINUE
        end
        if values[src] then
            goto CONTINUE
        end
        if src.value and src.value.uri then
            log.info("DEF")
            log.info(src.value.uri)
            results[#results+1] = {
                uri    = files.getOriginUri(src.value.uri),
                source = source,
                target = {
                    start  = 0,
                    finish = 0,
                    uri    = src.value.uri,
                }
            }
            goto CONTINUE
        end
        local root = guide.getRoot(src)
        if not root then
            goto CONTINUE
        end
        src = src.field or src.method or src.index or src
        if src.type == 'table' and src.parent.type ~= 'return' then
            goto CONTINUE
        end
        if  src.type == 'doc.class.name'
        and source.type ~= 'doc.type.name'
        and source.type ~= 'doc.extends.name'
        and source.type ~= 'doc.see.name' then
            goto CONTINUE
        end
        log.info("DEF 2")
        log.info(root.uri)
        results[#results+1] = {
            target = src,
            uri    = files.getOriginUri(root.uri),
            source = source,
        }
        ::CONTINUE::
    end

    if #results == 0 then
        return nil
    end

    sortResults(results)

    return results
end
