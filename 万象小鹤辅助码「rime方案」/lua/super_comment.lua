--@amzxyz https://github.com/amzxyz/rime_zrm
--由于comment_format不管你的表达式怎么写，只能获得一类输出，导致的结果只能用于一个功能类别
--如果依赖lua_filter载入多个lua也只能实现一些单一的、不依赖原始注释的功能，有的时候不可避免的发生一些逻辑冲突
--所以此脚本专门为了协调各式需求，逻辑优化，实现参数自定义，功能可开关，相关的配置跟着方案文件走，如下所示：
--将如下相关位置完全暴露出来，注释掉其它相关参数--
--  comment_format: {comment}   #将注释以词典字符串形式完全暴露，通过super_comment.lua完全接管。
--  spelling_hints: 10          # 将注释以词典字符串形式完全暴露，通过super_comment.lua完全接管。
--在方案文件顶层置入如下设置--
--#Lua 配置: 超级注释模块
--super_comment:                          # 超级注释，子项配置 true 开启，false 关闭
--  corrector: true                       # 启用错音错词提醒，例如输入 geiyu 给予 获得 jǐ yǔ 提示
--  corrector_type: "{comment}"           # 新增一个提示类型，比如"【{comment}】" 
--  candidate_length: 1                   # 候选词辅助码提醒的生效长度，0为关闭，但建议使用开关或者快捷键实现      

-- #########################
-- # 辅助码拆分提示模块 (chaifen)
-- #########################
local CF = {}
function CF.init(env)
    -- 初始化拆分词典（reverse.bin 形式）
    env.chaifen_dict = ReverseLookup("wanxiang_lookup")
end
function CF.fini(env)
    env.chaifen = nil
    collectgarbage()
 end
-- 拆分功能：返回拆分注释
function CF.run(cand, env, initial_comment)
    local dict = env.chaifen_dict
    if not dict then return nil end

    local append = dict:lookup(cand.text)
    if append ~= "" then
        if initial_comment and initial_comment ~= "" then
            return append
        end
    end
    return nil
end
-- #########################
-- # 错音错字提示模块 (Corrector)
-- #########################
local CR = {}
local corrections_cache = nil  -- 用于缓存已加载的词典

function CR.init(env)
    local auto_delimiter = env.settings.auto_delimiter or " "
    local corrections_file_path = rime_api.get_user_data_dir() .. "/cn_dicts/corrections.dict.yaml"

    -- 使用设置好的 corrector_type 和样式
    CR.style = env.settings.corrector_type or '{comment}'
    if corrections_cache then
        CR.corrections = corrections_cache
        return
    end

    local corrections = {}
    local file = io.open(corrections_file_path, "r")

    if file then
        for line in file:lines() do
            if not line:match("^#") then
                local text, code, weight, comment = line:match("^(.-)\t(.-)\t(.-)\t(.-)$")
                if text and code then
                    text = text:match("^%s*(.-)%s*$")
                    code = code:match("^%s*(.-)%s*$")
                    comment = comment and comment:match("^%s*(.-)%s*$") or ""
                    -- 用自动分隔符替换空格
                    comment = comment:gsub("%s+", auto_delimiter)
                    code = code:gsub("%s+", auto_delimiter)
                    corrections[code] = { text = text, comment = comment }
                end
            end
        end
        file:close()
        corrections_cache = corrections
        CR.corrections = corrections
    end
end
function CR.run(cand, env)
    -- 使用候选词的 comment 作为 code，在缓存中查找对应的修正
    local correction = nil
    if corrections_cache then
        correction = corrections_cache[cand.comment]
    end
    if correction and cand.text == correction.text then
        -- 用新的注释替换默认注释
        local final_comment = CR.style:gsub("{comment}", correction.comment)
        return final_comment
    end
    return nil
end
-- #########################
-- # 辅助码提示模块 (Fuzhu)
-- #########################
local FZ = {}
function FZ.run(cand, env, initial_comment)
    local length = utf8.len(cand.text)
    local final_comment = nil
    -- 确保候选词长度检查使用从配置中读取的值
    if env.settings.fuzhu_code_enabled and length <= env.settings.candidate_length then
        local comment_type = env.settings.comment_type
        local segments = {}
        -- 先用空格将分隔符分成多个片段
        local auto_delimiter = env.settings.auto_delimiter or " "
        for segment in string.gmatch(initial_comment, "[^" .. auto_delimiter .. "]+") do
            table.insert(segments, segment)
        end
        -- 根据 comment_type 决定处理方式
        if comment_type == "fuzhu" then
            -- 提取分号后面的所有字符
            local fuzhu_comments = {}
            for _, segment in ipairs(segments) do
                local match = segment:match(";(.+)$")
                if match then
                    table.insert(fuzhu_comments, match)
                end
            end
            -- 将提取的拼音片段用空格连接起来
            if #fuzhu_comments > 0 then
                final_comment = table.concat(fuzhu_comments, ",")
            end
        elseif comment_type == "tone" then
            -- 提取分号前面的所有字符
            local tone_comments = {}
            for _, segment in ipairs(segments) do
                local match = segment:match("^(.-);")
                if match then
                    table.insert(tone_comments, match)
                end
            end
            -- 将提取的拼音片段用空格连接起来
            if #tone_comments > 0 then
                final_comment = table.concat(tone_comments, ",")
            end
        end
    else
        -- 如果候选词长度超过指定值，返回空字符串
        final_comment = ""
    end
    return final_comment or ""  -- 确保返回最终值
end
-- ################################
-- 部件组字返回的注释（radical_pinyin）
-- ################################
local AZ = {}
-- 处理函数，只负责处理候选词的注释
function AZ.run(cand, env, initial_comment)
    local final_comment = nil  -- 初始化最终注释为空

    -- 使用空格将注释分割成多个片段
    local segments = {}
    for segment in initial_comment:gmatch("[^%s]+") do
        table.insert(segments, segment)
    end
    local pinyins = {}  -- 存储多个拼音
    local fuzhu = nil   -- 辅助码
    -- 遍历分割后的片段，提取拼音和辅助码
    for _, segment in ipairs(segments) do
        local pinyin = segment:match("^[^;]+")  -- 提取注释中的拼音部分
        local fz = segment:match("^[^;]*;?(.*)")  -- 提取分号后面的所有字符作为辅助码（允许缺失）

        if pinyin then
            table.insert(pinyins, pinyin)  -- 收集拼音
        end

        if fz then
            fuzhu = fz  -- 获取第一个辅助码
        end
    end
    -- 如果存在拼音和辅助码，则生成最终注释
    if #pinyins > 0 then
        local pinyin_str = table.concat(pinyins, ",")  -- 用逗号分隔多个拼音
        if fuzhu and fuzhu ~= "" then
            -- 存在辅助码时，生成带 "辅" 的注释
            final_comment = string.format("〔音%s 辅%s〕", pinyin_str, fuzhu)
        else
            -- 不存在辅助码时，只生成带拼音的注释
            final_comment = string.format("〔音%s〕", pinyin_str)
        end
    end
    return final_comment or ""  -- 确保返回最终值
end
-- #########################
-- 主函数：根据优先级处理候选词的注释
-- #########################
-- 主函数：根据优先级处理候选词的注释
local ZH = {}
function ZH.init(env)
    local config = env.engine.schema.config
    local delimiter = config:get_string('speller/delimiter') or " '"
    local auto_delimiter = delimiter:sub(1, 1)
    -- 检查开关状态
    local is_fuzhu_enabled = env.engine.context:get_option("fuzhu_switch")
    local is_chaifen_enabled = env.engine.context:get_option("chaifen_switch")
    -- 设置辅助码功能
    env.settings = {
        delimiter = delimiter,
        auto_delimiter = auto_delimiter,
        corrector_enabled = config:get_bool("super_comment/corrector") or true,  -- 错音错词提醒功能
        corrector_type = config:get_string("super_comment/corrector_type") or "{comment}",  -- 提示类型
        fuzhu_code_enabled = is_fuzhu_enabled,  -- 辅助码提醒功能通过开关控制
        chaifen_enabled = is_chaifen_enabled,  -- 辅助码拆分提醒功能通过开关控制
        comment_type = config:get_string("super_comment/comment_type") or "fuzhu",  -- 提示类型辅助或者声调fuzhu or tone
        candidate_length = tonumber(config:get_string("super_comment/candidate_length")) or 1,  -- 候选词长度
    }
end
function ZH.func(input, env)
    -- 初始化
    ZH.init(env)
    CR.init(env)
    CF.init(env)

    -- 声明反查模式的 tag 状态
    local seg = env.engine.context.composition:back()
    env.is_radical_mode = seg and (
        seg:has_tag("radical_lookup")
        or seg:has_tag("reverse_stroke")
        or seg:has_tag("add_user_dict")
    ) or false

    local input_str = env.engine.context.input or ""
    local index = 0
    for cand in input:iter() do
        index = index + 1
        local initial_comment = cand.comment
        local final_comment = initial_comment
    
        -- 辅助码处理
        if env.settings.fuzhu_code_enabled then
            local fz_comment = FZ.run(cand, env, initial_comment)
            if fz_comment then
                final_comment = fz_comment
            end
        else
            if final_comment ~= initial_comment then
                -- 有其他模块修改过注释，保留
            elseif input_str:match("//") and index == 1 then  --匹配pin造词状态
            elseif input_str:match("^[VRNU/]") then
                -- 输入包含 //，首选项保留注释
            else
                -- 其他情况清空
                final_comment = ""
            end
        end
        -- 拆分辅助码
        if env.settings.chaifen_enabled then
            local cf_comment = CF.run(cand, env, initial_comment)
            if cf_comment then
                final_comment = cf_comment
            end
        end

        -- 错音错词提示
        if env.settings.corrector_enabled then
            local cr_comment = CR.run(cand, env, initial_comment)
            if cr_comment then
                final_comment = cr_comment
            end
        end

        -- 部件组字注释
        if env.is_radical_mode then
            local az_comment = AZ.run(cand, env, initial_comment)
            if az_comment then
                final_comment = az_comment
            end
        end

        -- 更新最终注释
        if final_comment ~= initial_comment then
            cand:get_genuine().comment = final_comment
        end

        yield(cand)
    end
end

return {
    CR = CR,
    CF = CF,
    FZ = FZ,
    AZ = AZ,
    ZH = ZH,
    func = ZH.func
}