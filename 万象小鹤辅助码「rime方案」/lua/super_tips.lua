local _db_pool = _db_pool or {}
local function wrapLevelDb(dbname, mode)
    -- 保持原有数据库连接逻辑不变
    _db_pool[dbname] = _db_pool[dbname] or LevelDb(dbname)
    local db = _db_pool[dbname]
    if db and not db:loaded() then
        if mode then
            db:open()
        else
            db:open_read_only()
        end
    end
    return db
end

local M = {}
local S = {}

local function ensure_dir_exist(dir)
    -- 保持原有目录创建逻辑不变
    local sep = package.config:sub(1,1)
    dir = dir:gsub([["]], [[\"]])
    if sep == "/" then
        os.execute('mkdir -p "'..dir..'" 2>/dev/null')
    end
end

function M.init(env)
    -- 移除设备判断，始终创建目录
    local user_lua_dir = rime_api.get_user_data_dir() .. "/lua"
    ensure_dir_exist(user_lua_dir)
    
    local db = wrapLevelDb('lua/tips', true)
    -- 保持原有文件加载逻辑不变
    -- [...]
end

function M.func(input, env)
    local segment = env.engine.context.composition:back()
    if not segment then return 2 end
    
    local db = wrapLevelDb("lua/tips", false)
    local input_text = env.engine.context.input or ""
    local stick_phrase = db:fetch(input_text)

    -- 统一处理逻辑：
    local first_cand, candidates = nil, {}
    for cand in input:iter() do
        if not first_cand then first_cand = cand end
        table.insert(candidates, cand)
    end
    
    -- 合并匹配逻辑
    local match = stick_phrase or (first_cand and db:fetch(first_cand.text))
    if env.engine.context:get_option("super_tips") and match then
        segment.prompt = "〔" .. match .. "〕"
    else
        segment.prompt = ""
    end
    
    for _, cand in ipairs(candidates) do
        yield(cand)
    end
end

function S.func(key, env)
    local context = env.engine.context
    local segment = context.composition:back()
    local input_text = context.input or ""
    if not segment then return 2 end
    
    -- 统一按键处理逻辑
    local db = wrapLevelDb("lua/tips", false)
    local stick_phrase = db:fetch(input_text)
    local selected_cand = context:get_selected_candidate()
    local match = stick_phrase or (selected_cand and db:fetch(selected_cand.text))
    
    if context:get_option("super_tips") and key:repr() == env.engine.schema.config:get_string("key_binder/tips_key") then
         local formatted = (match and (match:match(".+:(.*)") or match:match(".+：(.*)"))) or (match and (match:match("〔.+:(.*)〕") or match:match("〔.+：(.*)〕"))) or ""
        env.engine:commit_text(formatted)
        context:clear()
        return 1
    end
    return 2
end

return { M = M, S = S }