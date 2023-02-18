local files = require 'files'
local guide = require 'core.guide'
local vm = require 'vm'

return function (uri)
    local ast = files.getAst(uri)
    if not ast then
        return
    end
    local results = {}

    -- every source that calls something in the file
    -- change to not make sure it is in the visible ranges
    -- this is where types/auto complete can transfer from different files (or not?)

    guide.eachSourceType(ast.ast, "call", function(source)
        log.info("CALL LINK")

        if source.node.special == "require" then
            if source.args and source.args[1] then
                local defs = vm.getDefs(source.args[1])
                for _, def in ipairs(defs) do
                    if def.uri then
                        results[#results+1] = {
                            range = files.range(uri, source.args[1].start, source.args[1].finish),
                            tooltip = "Go To Script",
                            target = def.uri
                        }
                    end
                end
            end
        ---- KNIT EXTENSION
        -- lets you click and navigate to the knit file its referencing
        -- doesnt work with some file names
        -- puts links on the "local service/controller and the definition aka declaration and definition"
        -- gotta do automatically making service/controller delcarations and definitions
        -- and auto completion across different knit files (proto.on completion)
        elseif source.node.field and (source.node.field[1] == "GetService" or source.node.field[1] == "GetController") then
            -- assuming this is knit (only thing that has getSErvice and uses a dot)
            local serviceName = source.args[1][1]
            local serviceUri
            
            for _, fileUri in ipairs(files.getAllUris()) do
                if fileUri:find(serviceName) then
                    serviceUri = fileUri
                    
                    if fileUri:find("init%.lua") then
                        -- if this was a init.lua file under a folder, this would be where the real methods are located
                        -- so stop here and make sure nothing overwrites it
                        log.info("DOCUMENT LINK STOP FULL STOP")
                        log.info(serviceUri)
                        break
                    end
                end
            end

            results[#results+1] = {
                range = files.range(uri, source.start, source.finish),
                tooltip = "Go To Script",
                target = serviceUri
            }

            local status = guide.status()
            guide.searchRefs(status, source.parent.parent, "def")
            local statusResults = status.results

            for _, result in ipairs(statusResults) do
                if result.type == "local" then
                    results[#results+1] = {
                        range = files.range(uri, result.start, result.finish),
                        tooltip = "Go To Script",
                        target = serviceUri
                    }
                end
            end
        end
        ---- KNIT EXTENSION

    end)
    if #results == 0 then
        return nil
    end
    return results
end