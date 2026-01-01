script_name("CosyTelegram")
script_version("2.4")
--[[
CosyTelegram - Управление скриптом из Telegram
Оставлен только функционал Telegram управления
v2.1 - Добавлена функция получения статистики
v2.3 - Исправлена ошибка "cannot resume non-suspended coroutine"
v2.4 - Добавлено автообновление с GitHub
--]]

local TAG = ':robot: {7B68EE}[TG] {CFCFCF}CosyTelegram | {9B9B9B}'
local c_main = '{9B9B9B}'

require 'lib.moonloader'
local samp = require 'samp.events'
local effil = require 'effil'
local inicfg = require 'inicfg'
local encoding = require 'encoding'
encoding.default = 'CP1251'
u8 = encoding.UTF8

-- Переменные скрипта
local main_window_state = false
local terminate_session = nil
local active = false
local updateid = nil
local myid = nil
local myNick = nil
local CheckStat = false -- Флаг для запроса статистики

-- Переменные для автообновления
local auto_update_enabled = false -- Включена ли автообновление
local repo_user = '' -- Пользователь репозитория GitHub
local repo_name = 'CosyTelegram' -- Имя репозитория GitHub
local current_version = script_version -- Текущая версия скрипта

-- JSON utilities - безопасная загрузка
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

-- Конфигурация
local mainIni = inicfg.load({
    settings = {
        scriptName = u8'ctg',
        selected_item = 0,
        -- Настройки автообновления
        auto_update = true,  -- Включить автообновление по умолчанию
        repo_user = '',   -- Пользователь репозитория GitHub (оставьте пустым для примера)
        repo_name = 'CosyTelegram'  -- Имя репозитория
    },
    telegram = {
        chat_id = '-1003122040330',
        token = '8386128632:AAHDTJlFv8kkpt1t2Etnut7_R1HXpjxW344'
    }
}, 'CosyTelegram')

if not doesFileExist('moonloader/config/CosyTelegram.ini') then
    inicfg.save(mainIni, 'CosyTelegram.ini')
end

-- Функции для URL кодирования
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

-- Функция экранирования для MarkdownV2
function MarkdownV2(text)
    if not text or type(text) ~= "string" then return text end
    local escape_chars = {'_', '*', '`', '[', ']', '(', ')', '~', '>', '<', '#', '+', '-', '=', '|', '{', '}', '.', '!'}

    for _, char in ipairs(escape_chars) do
        text = text:gsub('%'..char, '\\'..char)
    end

    return text
end

-- Асинхронные HTTP запросы
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
-- АВТООБНОВЛЕНИЕ С GITHUB
-- ===============================

-- Функция сравнения версий (semver)
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

-- Функция проверки обновлений
local function checkForUpdates()
    if not auto_update_enabled or repo_user == '' or repo_name == '' then
        msg_telegram("Автообновление отключено или не настроен репозиторий")
        return
    end
    
    local url = string.format('https://api.github.com/repos/%s/%s/releases/latest', 
        repo_user, repo_name)
    
    async_http_request(url, '', function(response)
        if not response or response == '' then
            msg_telegram("Не удалось получить информацию о версии с GitHub")
            return
        end
        
        local ok, data = pcall(decodeJson, response)
        if not ok or not data or not data.tag_name then
            msg_telegram("Не удалось разобрать ответ от GitHub")
            return
        end
        
        local latest_version = data.tag_name:gsub('v', '')
        local current_ver = current_version:gsub('v', '')
        
        msg_telegram("Текущая версия: " .. current_version .. ", актуальная на GitHub: " .. latest_version)
        
        if compareVersions(current_ver, latest_version) < 0 then
            msg_telegram("Доступно обновление! Версия: " .. latest_version)
            
            local update_message = string.format(
                "?? Доступно обновление для CosyTelegram!\n\n" ..
                "Версия: %s\n" ..
                "Текущая: %s\n" ..
                "Обновить?\n" ..
                "Через 10 сек начнется скачивание...",
                latest_version, current_version
            )
            
            sendTelegramNotification(MarkdownV2(update_message))
            
            -- Запускаем скачивание с задержкой
            lua_thread.create(function()
                wait(10000) -- 10 секунд
                downloadUpdate(data)
            end)
        elseif compareVersions(current_ver, latest_version) > 0 then
            msg_telegram("У вас установлена новее версия: " .. latest_version)
        else
            msg_telegram("У вас установлена актуальная версия")
        end
    end)
end

-- Функция скачивания обновления
local function downloadUpdate(release_data)
    if not release_data or not release_data.html_url then
        msg_telegram("Не удалось найти ссылку на скачивание")
        return
    end
    
    local download_url = release_data.html_url
    
    msg_telegram("Скачивание обновления с GitHub...")
    
    async_http_request(download_url, '', function(response)
        if not response or response == '' then
            msg_telegram("Не удалось скачать обновление")
            return
        end
        
        local script_path = thisScript().path
        local update_path = script_path .. ".update"
        
        -- Сохраняем скачанный файл
        local file = io.open(update_path, "wb")
        if file then
            file:write(response)
            file:close()
            
            -- Запускаем обновление
            updateScript(update_path)
        else
            msg_telegram("Не удалось создать файл обновления")
        end
    end)
end

-- Функция обновления скрипта
local function updateScript(update_file)
    msg_telegram("Установка обновления...")
    
    local script_path = thisScript().path
    local backup_path = script_path .. ".backup"
    
    -- Создаем бекап текущей версии
    os.remove(backup_path)
    os.rename(script_path, backup_path)
    
    -- Копируем обновление
    os.copy(update_file, script_path)
    
    -- Удаляем временный файл
    os.remove(update_file)
    os.remove(backup_path)
    
    msg_telegram("Обновление установлено!")
    msg_telegram("Перезагрузка скрипта через 3 секунды...")
    
    lua_thread.create(function()
        wait(3000)
        thisScript():reload()
    end)
end

-- Получение информации об игроке
function getMyInfo()
    local res, player_id = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if res then
        myid = player_id
        myNick = sampGetPlayerNickname(myid)
    end
end

-- Отправка уведомления в Telegram
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
                msg_telegram("[Ошибка] Не удалось отправить уведомление")
            end
        end
    )
end

-- Отправка уведомления с кнопками
function sendTelegramNotificationWithButtons(msg, buttons)
    if not msg or not buttons then return end
    local url = 'https://api.telegram.org/bot'.. mainIni.telegram.token ..
                '/sendMessage?chat_id='.. mainIni.telegram.chat_id ..
                '&text='.. msg ..
                '&parse_mode=MarkdownV2'..
                '&reply_markup='.. encodeUrl(encodeJson(buttons))

    async_http_request(url, '', function(result)
        if not result then
            print("Ошибка при отправке сообщения в Telegram")
            return
        end

        local ok, response = pcall(decodeJson, result)
        if ok and response then
            if not response.ok then
                print("Ошибка Telegram API:", response.description)
            end
        else
            print("Не удалось разобрать ответ от Telegram")
        end
    end)
end

-- Персональная панель управления
function TGPersonalPanel()
    getMyInfo()

    local msg_text = MarkdownV2(myNick .. '[' .. myid .. '] На связи.')

    local reply_markup = {
        inline_keyboard = {
            {
                { text = "Оффнуться", callback_data = "QQButton" },
                { text = "rec 5m", callback_data = "Rec5Button" },
                { text = "rec 10m", callback_data = "Rec10Button" },
                { text = "'Ау'", callback_data = "SendAyButton" },
                { text = "get stat", callback_data = "StatButton" }
            }
        }
    }
    sendTelegramNotificationWithButtons(encodeUrl(msg_text), reply_markup)
end

-- Уведомление об упоминании
function TGNotifyMention(msg_text, trigger)
    getMyInfo()

    local clean_msg = msg_text:gsub('{......}', '')
    clean_msg = 'Требуется кассир '.. myNick ..'\n'.. clean_msg

    clean_msg = MarkdownV2(clean_msg)

    clean_msg = clean_msg:gsub(trigger, '**`'.. trigger ..'`**')

    local reply_markup = {
        inline_keyboard = {
            {
                { text = "Оффнуться", callback_data = "QQButton" },
                { text = "Выезд из штата", callback_data = "MessageAndQQButton" },
                { text = "'Ау'", callback_data = "SendAyButton" },
                { text = "stap", callback_data = "StapButton" }
            }
        }
    }

    sendTelegramNotificationWithButtons(encodeUrl(clean_msg), reply_markup)
end

-- Получение последнего обновления
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

-- Обработка сообщений из Telegram
function processing_telegram_messages(result)
    if not result then return end
    local ok, proc_table = pcall(decodeJson, result)
    if not ok or not proc_table or not proc_table.ok then return end

    if proc_table.ok then
        if proc_table.result and #proc_table.result > 0 then
            local res_table = proc_table.result[1]
            if res_table and res_table.update_id ~= updateid then
                updateid = res_table.update_id

                -- Обработка текстовых сообщений
                if res_table.message then
                    local message_from_user = res_table.message.text
                    if message_from_user then
                        local text = u8:decode(message_from_user) .. ' '

                        -- Команда для получения панели
                        if text:match('^all') then
                            TGPersonalPanel()
                        -- Команда для выполнения команд в чате
                        elseif text:find("^#.+, .+") then
                            local who, command = string.match(text, "^#(.+), (.+)")
                            getMyInfo()
                            if who and command and (tonumber(who) == myid or who == myNick or who == "all") then
                                lua_thread.create(function()
                                    wait(200)
                                    sampProcessChatInput(command)
                                    sendTelegramNotification(MarkdownV2(myNick .. '[' .. myid .. '] отправил '.. command))
                                end)
                            else
                                sendTelegramNotification(MarkdownV2('Ошибка: Не могу выполнить команду для "' .. who .. '". Проверьте ID или ник.'))
                            end
                        end
                    end
                -- Обработка нажатий на кнопки
                elseif res_table.callback_query then
                    getMyInfo()
                    if res_table.callback_query.message and
                       res_table.callback_query.message.text and
                       res_table.callback_query.message.text:find(myNick) then
                        local callback_data = res_table.callback_query.data

                        if callback_data == "QQButton" then
                            -- Оффнуться
                            raknetEmulPacketReceiveBitStream(PACKET_DISCONNECTION_NOTIFICATION, raknetNewBitStream())
                            raknetDeleteBitStream(raknetNewBitStream())
                            sendTelegramNotification(MarkdownV2(myNick .. '[' .. myid .. '] вышел из игры.'))

                        elseif callback_data == "MessageAndQQButton" then
                            -- Сообщение в рацию и оффнуться
                            lua_thread.create(function()
                                sampSendChat('/r Извините, но я уже уезжаю из штата')
                                wait(7000)
                                raknetEmulPacketReceiveBitStream(PACKET_DISCONNECTION_NOTIFICATION, raknetNewBitStream())
                                raknetDeleteBitStream(raknetNewBitStream())
                                sendTelegramNotification(MarkdownV2(myNick .. '[' .. myid .. '] отправил сообщение об оффе.\nВы вышли из игры.'))
                            end)

                        elseif callback_data == "SendAyButton" then
                            -- Отправить "Ау" в рацию
                            sampSendChat("/r Ау")
                            sendTelegramNotification(MarkdownV2(myNick .. '[' .. myid .. "] отправлил сообщение 'Ау' в рацию."))

                        elseif callback_data == "StapButton" then
                            -- Отмена выхода
                            if terminate_session and terminate_session:status() == 'yielded' then
                                terminate_session:terminate()
                                active = false
                                msg('Telegram | Галя, отмена!!')
                                sendTelegramNotification(MarkdownV2(myNick .. '[' .. myid .. "] передумал выходить."))
                            end

                        elseif callback_data == "Rec5Button" then
                            -- Реконнект 5 минут
                            rec(300000)

                        elseif callback_data == "Rec10Button" then
                            -- Реконнект 10 минут
                            rec(600000)

                        elseif callback_data == "StatButton" then
                            -- Получить статистику
                            CheckStat = true
                            sampSendChat('/stats')
                            sendTelegramNotification(MarkdownV2(myNick .. '[' .. myid .. '] запросил статистику.'))
                        end
                    end
                end
            end
        end
    end
end

-- Получение обновлений от Telegram
function get_telegram_updates()
    while not updateid do wait(1) end
    local reject = function() end
    local args = ''
    while true do
        local url = 'https://api.telegram.org/bot'.. mainIni.telegram.token ..
              '/getUpdates?chat_id='.. mainIni.telegram.chat_id ..
              '&offset=-1'
        local runner = requestRunner()  -- Создаем новый runner для каждого запроса
        threadHandle(runner, url, args, processing_telegram_messages, reject)
        wait(500)
    end
end

-- Реконнект с таймером
function rec(timee)
    if not timee or timee <= 0 then
        msg_telegram("Ошибка: Некорректное время для реконнекта")
        return
    end
    lua_thread.create(function()
        msg_telegram("Отключаемся. Реконнект через " .. (timee/1000) .. " сек.")
        raknetEmulPacketReceiveBitStream(PACKET_DISCONNECTION_NOTIFICATION, raknetNewBitStream())
        raknetDeleteBitStream(raknetNewBitStream())
        wait(timee)
        sampDisconnectWithReason(0)
        sampSetGamestate(GAMESTATE_WAIT_CONNECT)
    end)
end

-- Вспомогательная функция для сообщений
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

-- Обработчик диалогов для перехвата статистики
function samp.onShowDialog(did, style, title, b1, b2, text)
    -- Обработка запроса статистики
    if CheckStat and title then
        -- Отладка: показываем информацию о диалоге
        msg_telegram("Диалог: " .. (title or "nil") .. ", CheckStat: " .. tostring(CheckStat))

        -- Убираем цвета SA-MP и отправляем в Telegram
        if text and text ~= '' then
            -- Удаляем цвета SA-MP
            local clean_text = text:gsub('{......}', '')

            -- Пропускаем пустые сообщения
            if clean_text:gsub('%s', '') ~= '' then
                local formatted_text = "?? *" .. MarkdownV2("Статистика") .. "*\n\n"
                formatted_text = formatted_text .. MarkdownV2(clean_text)

                -- Отправляем в Telegram
                sendTelegramNotification(formatted_text)
                msg_telegram("Статистика отправлена в Telegram")
            else
                msg_telegram("Статистика пуста, не отправляем")
            end
        else
            msg_telegram("Статистика пуста (text = nil), не отправляем")
        end

        CheckStat = false
        sampCloseCurrentDialogWithButton(1)
        return false
    end
end

-- Основная функция
function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end

    repeat
        wait(0)
    until sampIsLocalPlayerSpawned()

    -- Проверка настроек Telegram
    if not mainIni.telegram.token or mainIni.telegram.token == '' or
       mainIni.telegram.token == 'ВАШ_ТОКЕН_БОТА' then
        msg('{FF0000}[ОШИБКА]{FFFFFF} Не настроен токен бота!')
        msg('Отредактируйте moonloader/config/CosyTelegram.ini')
        return
    end

    if not mainIni.telegram.chat_id or mainIni.telegram.chat_id == '' or
       mainIni.telegram.chat_id == 'ВАШ_CHAT_ID' then
        msg('{FF0000}[ОШИБКА]{FFFFFF} Не настроен chat_id!')
        msg('Отредактируйте moonloader/config/CosyTelegram.ini')
        return
    end

    getMyInfo()
    getLastUpdate()

    -- ===============================
    -- ПРОВЕРКА ОБНОВЛЕНИЙ С GITHUB
    -- ===============================
    checkForUpdates()

    -- Регистрация команд
    sampRegisterChatCommand('removeconfig', function()
        os.remove('moonloader\\config\\CosyTelegram.ini')
        thisScript():reload()
        msg('Конфиг скрипта сброшен!')
    end)

    sampRegisterChatCommand('stap',function()
        if terminate_session and terminate_session:status() == 'yielded' then
            terminate_session:terminate()
            active = false
            msg('Telegram | Галя, отмена!!')
            sendTelegramNotification(MarkdownV2(myNick .. '[' .. myid .. "] передумал выходить."))
        else
            msg('Нет активной сессии для отмены.')
        end
    end)

    sampRegisterChatCommand('qq',function()
        raknetEmulPacketReceiveBitStream(PACKET_DISCONNECTION_NOTIFICATION, raknetNewBitStream())
        raknetDeleteBitStream(raknetNewBitStream())
    end)

    sampRegisterChatCommand('lrec',function(arg)
        if tonumber(arg) then
            msg('Перезаходим через '.. arg ..' сек.')
            arg = tonumber(arg) * 1000
            rec(arg)
        else
            msg('Введите кол-во секунд.')
        end
    end)

    sampRegisterChatCommand('tgpanel', function()
        TGPersonalPanel()
    end)

    sampRegisterChatCommand('tghelp', function()
        msg('Доступные команды:')
        msg('/tgpanel - отправить панель управления в Telegram')
        msg('/lrec [сек] - перезаход через указанное время')
        msg('/stap - отменить выход')
        msg('/qq - выйти из игры')
        msg('/removeconfig - сбросить конфиг')
    end)

    -- Запуск потока для Telegram
    lua_thread.create(get_telegram_updates)

    msg('CosyTelegram успешно загружен!')
    msg('Используйте /tghelp для списка команд')

    -- Основной цикл
    while true do
        wait(0)
    end
end
