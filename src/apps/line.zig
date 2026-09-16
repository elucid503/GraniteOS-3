pub const Event = enum {

    none,
    character,
    erase,
    submit,
    cancel,
    full,

};

pub const Line = struct {

    bytes: [256]u8 = undefined,
    len: usize = 0,
    carriage: bool = false,

    pub fn push(self: *Line, byte: u8) Event {

        const previous = self.carriage;
        self.carriage = byte == '\r';

        if (byte == '\n' and previous) return .none;
        if (byte == '\n' or byte == '\r') return .submit;
        if (byte == 3) {

            self.len = 0;
            return .cancel;

        }

        if (byte == 8 or byte == 127) {

            if (self.len == 0) return .none;
            self.len -= 1;
            return .erase;

        }

        if (byte < 32 or byte > 126) return .none;
        if (self.len == self.bytes.len) return .full;
        self.bytes[self.len] = byte;
        self.len += 1;

        return .character;

    }

};
