function eq(a, b) return math.abs(a - b) < 0.000001 end

function log10(x)
    if not x then return end
    return math.log(x, 10)
end

function todb(x)
    if not x then return end
    return 20 * log10(x)
end

function topower(x)
    if not x then return end
    return 10 ^ (x / 20)
end

function delete_item(item)
    if item then
        local track = reaper.GetMediaItem_Track(item)
        reaper.DeleteTrackMediaItem(track, item)
    end
end

function trim_item(item, keep_ranges)
    local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local left = item
    for i, range in ipairs(keep_ranges) do
        if not eq(range[1], item_pos) then
            local right = reaper.SplitMediaItem(left, range[1])
            delete_item(left)
            left = right
        end
        right = reaper.SplitMediaItem(left, range[2])
        reaper.SetMediaItemInfo_Value(left, "D_FADEINLEN", range.fade[1])
        reaper.SetMediaItemInfo_Value(left, "D_FADEOUTLEN", range.fade[2])
        left = right
        ::continue::
    end

    if #keep_ranges > 0 and keep_ranges[#keep_ranges][2] < item_pos + item_len then
        delete_item(left)
    end
end

function trim_edge(item, keep_ranges)
    for i, range in ipairs(keep_ranges) do
        reaper.BR_SetItemEdges(item, range[1], range[2])
    end
end

function expand_ranges(item, keep_ranges, left_pad, right_pad, fade_in, fade_out)
    local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    for i = 1, #keep_ranges do
        local left_inc = left_pad
        local right_inc = right_pad
        local actual_fade_in = fade_in
        local actual_fade_out = fade_out
        if (i > 1 and keep_ranges[i][1] - left_inc < keep_ranges[i - 1][2]) then
            left_inc = 0
            actual_fade_in = 0
        end
        if (i < #keep_ranges and keep_ranges[i][2] + right_inc > keep_ranges[i + 1][1]) then
            right_inc = 0
            actual_fade_out = 0
        end
        if keep_ranges[i][1] - left_inc <= item_pos + 0.000001 then
            left_inc = keep_ranges[i][1] - item_pos
            actual_fade_in = 0
        end
        if keep_ranges[i][2] + right_inc >= item_pos + item_len - 0.000001 then
            right_inc = item_pos + item_len - keep_ranges[i][2]
            actual_fade_out = 0
        end
        keep_ranges[i] = {
            keep_ranges[i][1] - left_inc,
            keep_ranges[i][2] + right_inc,
            fade = { actual_fade_in, actual_fade_out }
        }
    end
    return keep_ranges
end

function get_sample_val_and_pos(take, threshold)
    local ret = false
    if take == nil then return end

    local item = reaper.GetMediaItemTake_Item(take)
    if item == nil then return end

    local source = reaper.GetMediaItemTake_Source(take)
    if source == nil then return end

    local accessor = reaper.CreateTakeAudioAccessor(take)
    if accessor == nil then return end

    local aa_start = reaper.GetAudioAccessorStartTime(accessor)
    local aa_end = reaper.GetAudioAccessorEndTime(accessor)

    local take_source_len, length_is_QN = reaper.GetMediaSourceLength(source)
    if length_is_QN then return end

    local channels = reaper.GetMediaSourceNumChannels(source)
    local samplerate = reaper.GetMediaSourceSampleRate(source)
    if samplerate == 0 then return end

    local left_min = topower(threshold)
    local right_min = topower(threshold)

    local lv, rv
    local l, r

    local samples_per_channel = math.ceil((aa_end - aa_start) * samplerate)
    local sample_index
    local offset
    local samples_per_block = samplerate

    step = 1
    sample_index = 0
    offset = aa_start

    while sample_index < samples_per_channel do
        local buffer = reaper.new_array(samples_per_block * channels)
        local aa_ret = reaper.GetAudioAccessorSamples(accessor, samplerate, channels, offset, samples_per_block, buffer)
        if aa_ret <= 0 then
            goto next_block
        end

        for i = 0, samples_per_block - 1, step do
            if sample_index + i >= samples_per_channel then
                return
            end
            for j = 0, channels - 1 do
                local v = math.abs(buffer[channels * i + j + 1])
                if v > left_min then
                    lv = v
                    l = sample_index + i
                    goto found_l
                end
            end
        end
        ::next_block::
        sample_index = sample_index + samples_per_block
        offset = offset + samples_per_block / samplerate
        buffer.clear()
    end
    ::found_l::
    sample_index = samples_per_channel - 1
    offset = aa_end - samples_per_block / samplerate

    while sample_index >= 0 do
        local buffer = reaper.new_array(samples_per_block * channels)
        local aa_ret = reaper.GetAudioAccessorSamples(accessor, samplerate, channels, offset, samples_per_block, buffer)

        if aa_ret <= 0 then
            goto next_block
        end

        for i = samples_per_block - 1, 0, -step do
            if sample_index - (samples_per_block - 1 - i) < 0 then
                return
            end

            for j = 0, channels - 1 do
                local v = math.abs(buffer[channels * i + j + 1])

                if v > right_min and v < 1 then
                    rv = v
                    r = sample_index - (samples_per_block - 1 - i)

                    goto found_r
                end
            end
        end
        ::next_block::
        sample_index = sample_index - samples_per_block

        offset = offset - samples_per_block / samplerate
        buffer.clear()
    end
    ::found_r::
    reaper.DestroyAudioAccessor(accessor)

    if lv and rv then
        return lv and rv, l / samplerate, r / samplerate
    end
    return nil
end

local ret, input = reaper.GetUserInputs("参数设置", 2, "阈值(db),前后填充", "-55,0.2")
if not ret then return end
local threshold, pad = input:match("([^,]+),([^,]+)")

threshold = tonumber(threshold)
pad = tonumber(pad)
if not tonumber(threshold) or not tonumber(pad) then
    return
end


reaper.PreventUIRefresh(1)
reaper.Undo_BeginBlock()

local count_sel_items = reaper.CountSelectedMediaItems(0)
local track_items = {}

for i = 0, count_sel_items - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local track = reaper.GetMediaItem_Track(item)
    if not track_items[track] then track_items[track] = {} end
    table.insert(track_items[track], item)
end

for _, items in pairs(track_items) do
    for i, item in ipairs(items) do
        take = reaper.GetActiveTake(item)
        item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local ret, peak_pos_L, peak_pos_R = get_sample_val_and_pos(take, threshold)

        if ret and item_len > 0.1 then
            local ranges = { { item_pos + peak_pos_L, item_pos + peak_pos_R } }
            ranges = expand_ranges(item, ranges, pad, pad, 0, 0)
            trim_edge(item, ranges)
        end
        if ret == nil then
            delete_item(item)
        end
    end
end

reaper.Undo_EndBlock("修剪对象边缘", -1)
reaper.UpdateArrange()
reaper.PreventUIRefresh(-1)