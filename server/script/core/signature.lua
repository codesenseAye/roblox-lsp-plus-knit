local files      = require 'files'
local guide      = require 'core.guide'
local vm         = require 'vm'
local hoverLabel = require 'core.hover.label'
local hoverDesc  = require 'core.hover.description'
local lookBackward = require 'core.look-backward'

local function findNearCall(uri, ast, pos)
    local text = files.getText(uri)
    local nearCall
    guide.eachSourceContain(ast.ast, pos, function (src)
        if src.type == 'call'
        or src.type == 'table'
        or src.type == 'function' then
            -- call(),$
            if  src.finish <= pos
            and text:sub(src.finish, src.finish) == ')' then
                return
            end
            -- {},$
            if  src.finish <= pos
            and text:sub(src.finish, src.finish) == '}' then
                return
            end
            if not nearCall or nearCall.start <= src.start then
                nearCall = src
            end
        end
    end)
    if not nearCall then
        return nil
    end
    if nearCall.type ~= 'call' then
        return nil
    end
    return nearCall
end

local function countFuncArgs(source)
    local result = 0
    if not source.args or #source.args == 0 then
        return result
    end
    local lastArg = source.args[#source.args]
    if lastArg.type == "type.variadic" then
        return math.maxinteger
    elseif source.args[#source.args].type == '...' then
        return math.maxinteger
    end
    result = result + #source.args
    return result
end

local function makeOneSignature(source, oop, index)
    local label = hoverLabel(source, oop)
    label = label:gsub("%s*" .. INV .. "%s*%-%>.+", ""):gsub(INV, "")
    local argStart, argLabel = label:match("()(%b())$")
    argLabel = argLabel:sub(2, #argLabel - 1)
    for _, pattern in ipairs({"()", "{}", "[]", "<>"}) do
        argLabel = argLabel:gsub("%b" .. pattern, function(str)
            return ('_'):rep(#str)
        end)
    end
    local params = {}
    local i = 0
    for start, finish in argLabel:gmatch '%s*()[^,]+()' do
        i = i + 1
        params[i] = {
            label = {start + argStart, finish - 1 + argStart},
        }
    end
    if index > i and i > 0 then
        local lastLabel = params[i].label
        local text = label:sub(lastLabel[1], lastLabel[2])
        if text:sub(1, 3) == '...' then
            index = i
        end
    end
    return {
        label       = label,
        params      = params,
        index       = index,
        description = hoverDesc(source),
    }
end

local function eachFunctionAndOverload(value, callback)
    if value.type == "type.inter" then
        for _, obj in ipairs(guide.getAllValuesInType(value, "type.function")) do
            callback(obj)
        end
        return
    end
    callback(value)
    if value.bindDocs then
        for _, doc in ipairs(value.bindDocs) do
            if doc.type == 'doc.overload' then
                callback(doc.overload)
            end
        end
    end
    if value.overload then
        for _, overload in ipairs(value.overload) do
            callback(overload)
        end
    end
end

local function makeSignatures(call, pos, uri)
    local node = call.node

    local oop = node.type == 'method'
             or node.type == 'getmethod'
             or node.type == 'setmethod'

    local index

    if call.args then
        local args = {}
        for _, arg in ipairs(call.args) do
            if not arg.dummy then
                args[#args+1] = arg
            end
        end
        for i, arg in ipairs(args) do
            if arg.start <= pos and arg.finish >= pos then
                index = i
                break
            end
        end
        if not index then
            index = #args + 1
        end
    else
        index = 1
    end

    local defs = {}

    if oop then
        -- see if this is a knit method
        -- add to defs with the definition from the original file
    
        local srcFullText = files.getText(uri)

        local methodName, backwardPos = lookBackward.findWord(srcFullText, call.args.start - 1)
        
        if not methodName then
            -- this works when the user hasnt typed any parameters yet
            methodName, backwardPos = lookBackward.findWord(srcFullText, pos - 1)
        else
            -- the user has already started typing the parameters (atleast one)
        end
        
        local tableName, backwardPos = lookBackward.findWord(srcFullText, backwardPos - 2)

        if tableName and tableName == "Client" then
            tableName = lookBackward.findWord(srcFullText, backwardPos - 2)
        end

        if tableName and (tableName:find("Controller") or tableName:find("Service")) then
            -- log.tableInfo(source)
            local knitModuleUri

            for _, thisUri in ipairs(files.getAllUris()) do
                if thisUri:find(tableName) then
                    knitModuleUri = thisUri
                    
                    if thisUri:find("init%.lua") then
                        -- if this was a init.lua file under a folder, this would be where the real methods are located
                        -- so stop here and make sure nothing overwrites it
                        log.info("SIGNATURE STOP FULL STOP")
                        break
                    end
                end
            end

            if knitModuleUri then
                local uriAst = files.getAst(knitModuleUri)
                local knitModuleText = files.getText(knitModuleUri)

                guide.eachSourceType(uriAst.ast, "setmethod", function(src)
                    local textInRange = knitModuleText:sub(src.start, src.finish)
                    textInRange = textInRange:sub(textInRange:find(":") + 1, -1)
                
                    if textInRange == methodName then
                        table.insert(defs, src)
                    end
                end)
            end
        end
    end

    local signs = {}
    
    for _, def in ipairs(vm.getDefs(node, 0, {onlyDef = true, fullType = true})) do
        table.insert(defs, def)
    end
    
    local mark = {}

    for _, src in ipairs(defs) do
        src = guide.getObjectValue(src) or src
        if src.type == 'function'
        or src.type == 'doc.type.function'
        or src.type == 'type.function'
        or src.type == 'type.inter' then
            eachFunctionAndOverload(src, function(value)
                if not mark[value] then
                    mark[value] = true
                    if index == 1 or index <= countFuncArgs(value) then
                        signs[#signs+1] = makeOneSignature(value, oop, index)
                    end
                end
            end)
        end
    end

    return signs
end

local function isSpace(char)
    if char == ' '
    or char == '\n'
    or char == '\r'
    or char == '\t' then
        return true
    end
    return false
end

local function skipSpace(text, offset)
    for i = offset, 1, -1 do
        local char = text:sub(i, i)
        if not isSpace(char) then
            return i
        end
    end
    return 0
end

-- a signature is the thing that pops up when the user is typing the function parameters
return function (uri, pos)
    local ast = files.getAst(uri)
    if not ast then
        return nil
    end
    local text = files.getText(uri)
    pos = skipSpace(text, pos)
    local call = findNearCall(uri, ast, pos)
    if not call then
        return nil
    end
    log.info("SIGNATURE")
    local signs = makeSignatures(call, pos, uri)
    if not signs or #signs == 0 then
        return nil
    end
    return signs
end
