script_name("CosyTelegram")
script_version("2.4")


local TAG = ':robot: {7B68EE}[TG] {CFCFCF}CosyTelegram | {9B9B9B}'
local c_main = '{9B9B9B}'

require 'lib.moonloader'
local samp = require 'samp.events'
local effil = require 'effil'
local inicfg = require 'inicfg'
local encoding = require 'encoding'
encoding.default = 'CP1251'
u8 = encoding.UTF8

-- Ïåðåìåííûå ñêðèïòà
local main_window_state = false
local terminate_session = nil
local active = false
local updateid = nil
local myid = nil
local myNick = nil
local CheckStat = false -- Ôëàã äëÿ çàïðîñà ñòàòèñòèêè

-- Ïåðåìåííûå äëÿ àâòîîáíîâëåíèÿ
local auto_update_enabled = false -- Âêëþ÷åíà ëè àâòîîáíîâëåíèå
local repo_user = '' -- Ïîëüçîâàòåëü ðåïîçèòîðèÿ GitHub
local repo_name = 'CosyTelegram' -- Èìÿ ðåïîçèòîðèÿ GitHub
local current_version = script_version -- Òåêóùàÿ âåðñèÿ ñêðèïòà

-- JSON utilities - áåçîïàñíàÿ çàãðóçêà
local json = nil
local success, json_lib = pcall(require, 'dkjson')
if success then
    json = json_lib
else
    json = {
        encode = function(data)
            if type(data) ~= "table" then return tostring(data or "{}") end
            local str = "{"
            for k, v in pairs(data) do
                str = str .. '"' .. tostring(k) .. '":'
                if type(v) == "table" then
                    str = str .. json.encode(v) .. ","
                elseif type(v) == "string" then
                    str = str .. '"' .. tostring(v) .. '",'
                elseif type(v) == "boolean" then
                    str = str .. (v and "true" or "false") .. ","
                else
                    str = str .. tostring(v) .. ","
                end
            end
            return str:sub(1, -2) .. "}"
        end,
        decode = function(str)
            if type(str) ~= "string" then return {} end
            return {}
        end
    }
end

function encodeJson(data)
    if not data then return "{}" end
    if not json then return "{}" end
    local success, result = pcall(json.encode, data)
    if success and result then return result else return "{}" end
end

function decodeJson(jsonString)
    if not jsonString or type(jsonString) ~= "string" then return nil end
    if not json then return nil end
    local success, result = pcall(json.decode, jsonString)
    if success and result then return result else return nil end
end

-- Êîíôèãóðàöèÿ
local mainIni = inicfg.load({
    settings = {
        scriptName = u8'ctg',
        selected_item = 0,
        -- Íàñòðîéêè àâòîîáíîâëåíèÿ
        auto_update = true,  -- Âêëþ÷èòü àâòîîáíîâëåíèå ïî óìîë÷àíèþ
        repo_user = '',   -- Ïîëüçîâàòåëü ðåïîçèòîðèÿ GitHub (îñòàâüòå ïóñòûì äëÿ ïðèìåðà)
        repo_name = 'CosyTelegram'  -- Èìÿ ðåïîçèòîðèÿ
    },
    telegram = {
        chat_id = '-1003122040330',
        token = '8386128632:AAHDTJlFv8kkpt1t2Etnut7_R1HXpjxW344'
    }
}, 'CosyTelegram')

if not doesFileExist('moonloader/config/CosyTelegram.ini') then
    inicfg.save(mainIni, 'CosyTelegram.ini')
end

-- Ôóíêöèè äëÿ URL êîäèðîâàíèÿ
function encodeUrl(str)
    if not str then return "" end
    str = str:gsub(' ', '%+')
    str = str:gsub('\n', '%%0A')
    return u8:encode(str, 'CP1251')
end

function url_encode(str)
    if not str then return "" end
    local str = string.gsub(str, "\\", "\\\\")
    local str = string.gsub(str, "([^%w])", char_to_hex)
    return str
end

function char_to_hex(str)
    return string.format("%%%02X", string.byte(str))
end

-- Ôóíêöèÿ ýêðàíèðîâàíèÿ äëÿ MarkdownV2
function MarkdownV2(text)
    if not text or type(text) ~= "string" then return text end
    local escape_chars = {'_', '*', '`', '[', ']', '(', ')', '~', '>', '<', '#', '+', '-', '=', '|', '{', '}', '.', '!'}

    for _, char in ipairs(escape_chars) do
        text = text:gsub('%'..char, '\\'..char)
    end

    return text
end

-- Àñèíõðîííûå HTTP çàïðîñû
function requestRunner()
    return effil.thread(function(u, a)
        local https = require 'ssl.https'
        local ok, result = pcall(https.request, u, a)
        if ok then
            return {true, result}
        else
            return {false, result}
        end
    end)
end

function threadHandle(runner, url, args, resolve, reject)
    local t = runner(url, args)
    local r = t:get(0)
    while not r do
        r = t:get(0)
        wait(0)
    end
    local status = t:status()
    if status == 'completed' then
        local ok, result = r[1], r[2]
        if ok then
            if resolve then resolve(result) end
        else
            if reject then reject(result) end
        end
    elseif status == 'canceled' then
        if reject then reject(status) end
    else
        if reject then reject("Unknown error in thread") end
    end
end

function async_http_request(url, args, resolve, reject)
    local runner = requestRunner()
    if not reject then reject = function() end end
    lua_thread.create(function()
        threadHandle(runner, url, args, resolve, reject)
    end)
end

-- ===============================
-- ÀÂÒÎÎÁÍÎÂËÅÍÈÅ Ñ GITHUB
-- ===============================

-- Ôóíêöèÿ ñðàâíåíèÿ âåðñèé (semver)
local function compareVersions(v1, v2)
    local v1_parts = {}
    local v2_parts = {}
    
    for part in v1:gmatch("[^.]+") do
        table.insert(v1_parts, tonumber(part))
    end
    
    for part in v2:gmatch("[^.]+") do
        table.insert(v2_parts, tonumber(part))
    end
    
    for i = 1, 3 do
        if v1_parts[i] ~= v2_parts[i] then
            return v1_parts[i] > v2_parts[i] and 1 or -1
        end
    end
    
    return 0
end

-- Ôóíêöèÿ ïðîâåðêè îáíîâëåíèé
local function checkForUpdates()
    if not auto_update_enabled or repo_user == '' or repo_name == '' then
        msg_telegram("Àâòîîáíîâëåíèå îòêëþ÷åíî èëè íå íàñòðîåí ðåïîçèòîðèé")
        return
    end
    
    local url = string.format('https://api.github.com/repos/%s/%s/releases/latest', 
        repo_user, repo_name)
    
    async_http_request(url, '', function(response)
        if not response or response == '' then
            msg_telegram("Íå óäàëîñü ïîëó÷èòü èíôîðìàöèþ î âåðñèè ñ GitHub")
            return
        end
        
        local ok, data = pcall(decodeJson, response)
        if not ok or not data or not data.tag_name then
            msg_telegram("Íå óäàëîñü ðàçîáðàòü îòâåò îò GitHub")
            return
        end
        
        local latest_version = data.tag_name:gsub('v', '')
        local current_ver = current_version:gsub('v', '')
        
        msg_telegram("Òåêóùàÿ âåðñèÿ: " .. current_version .. ", àêòóàëüíàÿ íà GitHub: " .. latest_version)
        
        if compareVersions(current_ver, latest_version) < 0 then
            msg_telegram("Äîñòóïíî îáíîâëåíèå! Âåðñèÿ: " .. latest_version)
            
            local update_message = string.format(
                "?? Äîñòóïíî îáíîâëåíèå äëÿ CosyTelegram!\n\n" ..
                "Âåðñèÿ: %s\n" ..
                "Òåêóùàÿ: %s\n" ..
                "Îáíîâèòü?\n" ..
                "×åðåç 10 ñåê íà÷íåòñÿ ñêà÷èâàíèå...",
                latest_version, current_version
            )
            
            sendTelegramNotification(MarkdownV2(update_message))
            
            -- Çàïóñêàåì ñêà÷èâàíèå ñ çàäåðæêîé
            lua_thread.create(function()
                wait(10000) -- 10 ñåêóíä
                downloadUpdate(data)
            end)
        elseif compareVersions(current_ver, latest_version) > 0 then
            msg_telegram("Ó âàñ óñòàíîâëåíà íîâåå âåðñèÿ: " .. latest_version)
        else
            msg_telegram("Ó âàñ óñòàíîâëåíà àêòóàëüíàÿ âåðñèÿ")
        end
    end)
end

-- Ôóíêöèÿ ñêà÷èâàíèÿ îáíîâëåíèÿ
local function downloadUpdate(release_data)
    if not release_data or not release_data.html_url then
        msg_telegram("Íå óäàëîñü íàéòè ññûëêó íà ñêà÷èâàíèå")
        return
    end
    
    local download_url = release_data.html_url
    
    msg_telegram("Ñêà÷èâàíèå îáíîâëåíèÿ ñ GitHub...")
    
    async_http_request(download_url, '', function(response)
        if not response or response == '' then
            msg_telegram("Íå óäàëîñü ñêà÷àòü îáíîâëåíèå")
            return
        end
        
        local script_path = thisScript().path
        local update_path = script_path .. ".update"
        
        -- Ñîõðàíÿåì ñêà÷àííûé ôàéë
        local file = io.open(update_path, "wb")
        if file then
            file:write(response)
            file:close()
            
            -- Çàïóñêàåì îáíîâëåíèå
            updateScript(update_path)
        else
            msg_telegram("Íå óäàëîñü ñîçäàòü ôàéë îáíîâëåíèÿ")
        end
    end)
end

-- Ôóíêöèÿ îáíîâëåíèÿ ñêðèïòà
local function updateScript(update_file)
    msg_telegram("Óñòàíîâêà îáíîâëåíèÿ...")
    
    local script_path = thisScript().path
    local backup_path = script_path .. ".backup"
    
    -- Ñîçäàåì áåêàï òåêóùåé âåðñèè
    os.remove(backup_path)
    os.rename(script_path, backup_path)
    
    -- Êîïèðóåì îáíîâëåíèå
    os.copy(update_file, script_path)
    
    -- Óäàëÿåì âðåìåííûé ôàéë
    os.remove(update_file)
    os.remove(backup_path)
    
    msg_telegram("Îáíîâëåíèå óñòàíîâëåíî!")
    msg_telegram("Ïåðåçàãðóçêà ñêðèïòà ÷åðåç 3 ñåêóíäû...")
    
    lua_thread.create(function()
        wait(3000)
        thisScript():reload()
    end)
end

-- Ïîëó÷åíèå èíôîðìàöèè îá èãðîêå
function getMyInfo()
    local res, player_id = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if res then
        myid = player_id
        myNick = sampGetPlayerNickname(myid)
    end
end

-- Îòïðàâêà óâåäîìëåíèÿ â Telegram
function sendTelegramNotification(msg)
    if not msg then return end
    async_http_request(
        'https://api.telegram.org/bot' .. mainIni.telegram.token ..
        '/sendMessage?chat_id=' .. mainIni.telegram.chat_id ..
        '&text=' .. encodeUrl(msg:gsub('{......}', '')) ..
        '&parse_mode=MarkdownV2',
        '',
        function(result)
            if not result then
                msg_telegram("[Îøèáêà] Íå óäàëîñü îòïðàâèòü óâåäîìëåíèå")
            end
        end
    )
end

-- Îòïðàâêà óâåäîìëåíèÿ ñ êíîïêàìè
function sendTelegramNotificationWithButtons(msg, buttons)
    if not msg or not buttons then return end
    local url = 'https://api.telegram.org/bot'.. mainIni.telegram.token ..
                '/sendMessage?chat_id='.. mainIni.telegram.chat_id ..
                '&text='.. msg ..
                '&parse_mode=MarkdownV2'..
                '&reply_markup='.. encodeUrl(encodeJson(buttons))

    async_http_request(url, '', function(result)
        if not result then
            print("Îøèáêà ïðè îòïðàâêå ñîîáùåíèÿ â Telegram")
            return
        end

        local ok, response = pcall(decodeJson, result)
        if ok and response then
            if not response.ok then
                print("Îøèáêà Telegram API:", response.description)
            end
        else
            print("Íå óäàëîñü ðàçîáðàòü îòâåò îò Telegram")
        end
    end)
end

-- Ïåðñîíàëüíàÿ ïàíåëü óïðàâëåíèÿ
function TGPersonalPanel()
    getMyInfo()

    local msg_text = MarkdownV2(myNick .. '[' .. myid .. '] Íà ñâÿçè.')

    local reply_markup = {
        inline_keyboard = {
            {
                { text = "Îôôíóòüñÿ", callback_data = "QQButton" },
                { text = "rec 5m", callback_data = "Rec5Button" },
                { text = "rec 10m", callback_data = "Rec10Button" },
                { text = "'Àó'", callback_data = "SendAyButton" },
                { text = "get stat", callback_data = "StatButton" }
            }
        }
    }
    sendTelegramNotificationWithButtons(encodeUrl(msg_text), reply_markup)
end

-- Óâåäîìëåíèå îá óïîìèíàíèè
function TGNotifyMention(msg_text, trigger)
    getMyInfo()

    local clean_msg = msg_text:gsub('{......}', '')
    clean_msg = 'Òðåáóåòñÿ êàññèð '.. myNick ..'\n'.. clean_msg

    clean_msg = MarkdownV2(clean_msg)

    clean_msg = clean_msg:gsub(trigger, '**`'.. trigger ..'`**')

    local reply_markup = {
        inline_keyboard = {
            {
                { text = "Îôôíóòüñÿ", callback_data = "QQButton" },
                { text = "Âûåçä èç øòàòà", callback_data = "MessageAndQQButton" },
                { text = "'Àó'", callback_data = "SendAyButton" },
                { text = "stap", callback_data = "StapButton" }
            }
        }
    }

    sendTelegramNotificationWithButtons(encodeUrl(clean_msg), reply_markup)
end

-- Ïîëó÷åíèå ïîñëåäíåãî îáíîâëåíèÿ
function getLastUpdate()
    async_http_request(
        'https://api.telegram.org/bot'.. mainIni.telegram.token ..
        '/getUpdates?chat_id='.. mainIni.telegram.chat_id ..
        '&offset=-1',
        '',
        function(result)
            if not result then
                updateid = 1
                return
            end

            local ok, proc_table = pcall(decodeJson, result)
            if not ok or not proc_table or not proc_table.ok then
                updateid = 1
                return
            end

            if proc_table.result and #proc_table.result > 0 then
                local res_table = proc_table.result[1]
                if res_table then
                    updateid = res_table.update_id
                else
                    updateid = 1
                end
            else
                updateid = 1
            end
        end
    )
end

-- Îáðàáîòêà ñîîáùåíèé èç Telegram
function processing_telegram_messages(result)
    if not result then return end
    local ok, proc_table = pcall(decodeJson, result)
    if not ok or not proc_table or not proc_table.ok then return end

    if proc_table.ok then
        if proc_table.result and #proc_table.result > 0 then
            local res_table = proc_table.result[1]
            if res_table and res_table.update_id ~= updateid then
                updateid = res_table.update_id

                -- Îáðàáîòêà òåêñòîâûõ ñîîáùåíèé
                if res_table.message then
                    local message_from_user = res_table.message.text
                    if message_from_user then
                        local text = u8:decode(message_from_user) .. ' '

                        -- Êîìàíäà äëÿ ïîëó÷åíèÿ ïàíåëè
                        if text:match('^all') then
                            TGPersonalPanel()
                        -- Êîìàíäà äëÿ âûïîëíåíèÿ êîìàíä â ÷àòå
                        elseif text:find("^#.+, .+") then
                            local who, command = string.match(text, "^#(.+), (.+)")
                            getMyInfo()
                            if who and command and (tonumber(who) == myid or who == myNick or who == "all") then
                                lua_thread.create(function()
                                    wait(200)
                                    sampProcessChatInput(command)
                                    sendTelegramNotification(MarkdownV2(myNick .. '[' .. myid .. '] îòïðàâèë '.. command))
                                end)
                            else
                                sendTelegramNotification(MarkdownV2('Îøèáêà: Íå ìîãó âûïîëíèòü êîìàíäó äëÿ "' .. who .. '". Ïðîâåðüòå ID èëè íèê.'))
                            end
                        end
                    end
                -- Îáðàáîòêà íàæàòèé íà êíîïêè
                elseif res_table.callback_query then
                    getMyInfo()
                    if res_table.callback_query.message and
                       res_table.callback_query.message.text and
                       res_table.callback_query.message.text:find(myNick) then
                        local callback_data = res_table.callback_query.data

                        if callback_data == "QQButton" then
                            -- Îôôíóòüñÿ
                            raknetEmulPacketReceiveBitStream(PACKET_DISCONNECTION_NOTIFICATION, raknetNewBitStream())
                            raknetDeleteBitStream(raknetNewBitStream())
                            sendTelegramNotification(MarkdownV2(myNick .. '[' .. myid .. '] âûøåë èç èãðû.'))

                        elseif callback_data == "MessageAndQQButton" then
                            -- Ñîîáùåíèå â ðàöèþ è îôôíóòüñÿ
                            lua_thread.create(function()
                                sampSendChat('/r Èçâèíèòå, íî ÿ óæå óåçæàþ èç øòàòà')
                                wait(7000)
                                raknetEmulPacketReceiveBitStream(PACKET_DISCONNECTION_NOTIFICATION, raknetNewBitStream())
                                raknetDeleteBitStream(raknetNewBitStream())
                                sendTelegramNotification(MarkdownV2(myNick .. '[' .. myid .. '] îòïðàâèë ñîîáùåíèå îá îôôå.\nÂû âûøëè èç èãðû.'))
                            end)

                        elseif callback_data == "SendAyButton" then
                            -- Îòïðàâèòü "Àó" â ðàöèþ
                            sampSendChat("/r Àó")
                            sendTelegramNotification(MarkdownV2(myNick .. '[' .. myid .. "] îòïðàâëèë ñîîáùåíèå 'Àó' â ðàöèþ."))

                        elseif callback_data == "StapButton" then
                            -- Îòìåíà âûõîäà
                            if terminate_session and terminate_session:status() == 'yielded' then
                                terminate_session:terminate()
                                active = false
                                msg('Telegram | Ãàëÿ, îòìåíà!!')
                                sendTelegramNotification(MarkdownV2(myNick .. '[' .. myid .. "] ïåðåäóìàë âûõîäèòü."))
                            end

                        elseif callback_data == "Rec5Button" then
                            -- Ðåêîííåêò 5 ìèíóò
                            rec(300000)

                        elseif callback_data == "Rec10Button" then
                            -- Ðåêîííåêò 10 ìèíóò
                            rec(600000)

                        elseif callback_data == "StatButton" then
                            -- Ïîëó÷èòü ñòàòèñòèêó
                            CheckStat = true
                            sampSendChat('/stats')
                            sendTelegramNotification(MarkdownV2(myNick .. '[' .. myid .. '] çàïðîñèë ñòàòèñòèêó.'))
                        end
                    end
                end
            end
        end
    end
end

-- Ïîëó÷åíèå îáíîâëåíèé îò Telegram
function get_telegram_updates()
    while not updateid do wait(1) end
    local reject = function() end
    local args = ''
    while true do
        local url = 'https://api.telegram.org/bot'.. mainIni.telegram.token ..
              '/getUpdates?chat_id='.. mainIni.telegram.chat_id ..
              '&offset=-1'
        local runner = requestRunner()  -- Ñîçäàåì íîâûé runner äëÿ êàæäîãî çàïðîñà
        threadHandle(runner, url, args, processing_telegram_messages, reject)
        wait(500)
    end
end

-- Ðåêîííåêò ñ òàéìåðîì
function rec(timee)
    if not timee or timee <= 0 then
        msg_telegram("Îøèáêà: Íåêîððåêòíîå âðåìÿ äëÿ ðåêîííåêòà")
        return
    end
    lua_thread.create(function()
        msg_telegram("Îòêëþ÷àåìñÿ. Ðåêîííåêò ÷åðåç " .. (timee/1000) .. " ñåê.")
        raknetEmulPacketReceiveBitStream(PACKET_DISCONNECTION_NOTIFICATION, raknetNewBitStream())
        raknetDeleteBitStream(raknetNewBitStream())
        wait(timee)
        sampDisconnectWithReason(0)
        sampSetGamestate(GAMESTATE_WAIT_CONNECT)
    end)
end

-- Âñïîìîãàòåëüíàÿ ôóíêöèÿ äëÿ ñîîáùåíèé
function msg(text)
    if text then
        sampAddChatMessage(TAG .. '' .. text, -1)
    end
end

function msg_telegram(text)
    if text then
        sampAddChatMessage(':robot: {7B68EE}[TG] {9B9B9B}' .. text, -1)
    end
end

-- Îáðàáîò÷èê äèàëîãîâ äëÿ ïåðåõâàòà ñòàòèñòèêè
function samp.onShowDialog(did, style, title, b1, b2, text)
    -- Îáðàáîòêà çàïðîñà ñòàòèñòèêè
    if CheckStat and title then
        -- Îòëàäêà: ïîêàçûâàåì èíôîðìàöèþ î äèàëîãå
        msg_telegram("Äèàëîã: " .. (title or "nil") .. ", CheckStat: " .. tostring(CheckStat))

        -- Óáèðàåì öâåòà SA-MP è îòïðàâëÿåì â Telegram
        if text and text ~= '' then
            -- Óäàëÿåì öâåòà SA-MP
            local clean_text = text:gsub('{......}', '')

            -- Ïðîïóñêàåì ïóñòûå ñîîáùåíèÿ
            if clean_text:gsub('%s', '') ~= '' then
                local formatted_text = "?? *" .. MarkdownV2("Ñòàòèñòèêà") .. "*\n\n"
                formatted_text = formatted_text .. MarkdownV2(clean_text)

                -- Îòïðàâëÿåì â Telegram
                sendTelegramNotification(formatted_text)
                msg_telegram("Ñòàòèñòèêà îòïðàâëåíà â Telegram")
            else
                msg_telegram("Ñòàòèñòèêà ïóñòà, íå îòïðàâëÿåì")
            end
        else
            msg_telegram("Ñòàòèñòèêà ïóñòà (text = nil), íå îòïðàâëÿåì")
        end

        CheckStat = false
        sampCloseCurrentDialogWithButton(1)
        return false
    end
end

-- Îñíîâíàÿ ôóíêöèÿ
function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end

    repeat
        wait(0)
    until sampIsLocalPlayerSpawned()

    -- Ïðîâåðêà íàñòðîåê Telegram
    if not mainIni.telegram.token or mainIni.telegram.token == '' or
       mainIni.telegram.token == 'ÂÀØ_ÒÎÊÅÍ_ÁÎÒÀ' then
        msg('{FF0000}[ÎØÈÁÊÀ]{FFFFFF} Íå íàñòðîåí òîêåí áîòà!')
        msg('Îòðåäàêòèðóéòå moonloader/config/CosyTelegram.ini')
        return
    end

    if not mainIni.telegram.chat_id or mainIni.telegram.chat_id == '' or
       mainIni.telegram.chat_id == 'ÂÀØ_CHAT_ID' then
        msg('{FF0000}[ÎØÈÁÊÀ]{FFFFFF} Íå íàñòðîåí chat_id!')
        msg('Îòðåäàêòèðóéòå moonloader/config/CosyTelegram.ini')
        return
    end

    getMyInfo()
    getLastUpdate()

    -- ===============================
    -- ÏÐÎÂÅÐÊÀ ÎÁÍÎÂËÅÍÈÉ Ñ GITHUB
    -- ===============================
    checkForUpdates()

    -- Ðåãèñòðàöèÿ êîìàíä
    sampRegisterChatCommand('removeconfig', function()
        os.remove('moonloader\\config\\CosyTelegram.ini')
        thisScript():reload()
        msg('Êîíôèã ñêðèïòà ñáðîøåí!')
    end)

    sampRegisterChatCommand('stap',function()
        if terminate_session and terminate_session:status() == 'yielded' then
            terminate_session:terminate()
            active = false
            msg('Telegram | Ãàëÿ, îòìåíà!!')
            sendTelegramNotification(MarkdownV2(myNick .. '[' .. myid .. "] ïåðåäóìàë âûõîäèòü."))
        else
            msg('Íåò àêòèâíîé ñåññèè äëÿ îòìåíû.')
        end
    end)

    sampRegisterChatCommand('qq',function()
        raknetEmulPacketReceiveBitStream(PACKET_DISCONNECTION_NOTIFICATION, raknetNewBitStream())
        raknetDeleteBitStream(raknetNewBitStream())
    end)

    sampRegisterChatCommand('lrec',function(arg)
        if tonumber(arg) then
            msg('Ïåðåçàõîäèì ÷åðåç '.. arg ..' ñåê.')
            arg = tonumber(arg) * 1000
            rec(arg)
        else
            msg('Ââåäèòå êîë-âî ñåêóíä.')
        end
    end)

    sampRegisterChatCommand('tgpanel', function()
        TGPersonalPanel()
    end)

    sampRegisterChatCommand('tghelp', function()
        msg('Äîñòóïíûå êîìàíäû:')
        msg('/tgpanel - îòïðàâèòü ïàíåëü óïðàâëåíèÿ â Telegram')
        msg('/lrec [ñåê] - ïåðåçàõîä ÷åðåç óêàçàííîå âðåìÿ')
        msg('/stap - îòìåíèòü âûõîä')
        msg('/qq - âûéòè èç èãðû')
        msg('/removeconfig - ñáðîñèòü êîíôèã')
    end)

    -- Çàïóñê ïîòîêà äëÿ Telegram
    lua_thread.create(get_telegram_updates)

    msg('CosyTelegram óñïåøíî çàãðóæåí!')
    msg('Èñïîëüçóéòå /tghelp äëÿ ñïèñêà êîìàíä')

    -- Îñíîâíîé öèêë
    while true do
        wait(0)
    end
end
