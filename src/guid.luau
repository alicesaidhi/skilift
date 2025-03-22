local MAP = {"0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"}

@native local function generate_guid(): string
    local b = buffer.create(32)

    for i = 0, 31 do
        buffer.writeu8(b, i, string.byte(MAP[math.random(1, 16)]))
    end

    return buffer.tostring(b)
end

return generate_guid