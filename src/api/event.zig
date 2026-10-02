/// One input event, small enough to travel as a single IPC word.
pub const Event = packed struct(u64) {

    kind: Kind = .none,

    /// Key events: pressed or released. Button events: went down or up.
    pressed: bool = false,
    modifiers: Modifiers = .{},

    /// Key events: a `Key`. Button events: the button index. Motion and pointer events: held buttons.
    code: u8 = 0,

    /// The typed character of a key event as a Unicode code point, or zero.
    char: u16 = 0,

    /// Motion events carry a relative delta; pointer and button events a position in surface coordinates; resize events the screen size.
    x: i16 = 0,
    y: i16 = 0,

    pub const Kind = enum(u3) {

        none,
        key,
        motion,
        pointer,
        button,

        /// The window manager's close control was clicked.
        close,

        /// The screen changed size; `x` and `y` carry its new width and height.
        resize,
        _,

    };

    pub const Modifiers = packed struct(u4) {

        shift: bool = false,
        control: bool = false,
        alt: bool = false,
        super: bool = false,

    };

    pub fn key(self: Event) Key {

        return @enumFromInt(self.code);

    }

    /// Whether this is a press of `which` with exactly `held` modifiers.
    pub fn chord(self: Event, held: Modifiers, which: u8) bool {

        return self.kind == .key and self.pressed and @as(u4, @bitCast(self.modifiers)) == @as(u4, @bitCast(held)) and self.char | 0x20 == which;

    }

};

/// Physical keys; printable keys report `.character` with the typed character in `Event.char`.
pub const Key = enum(u8) {

    none,
    character,
    escape,
    enter,
    backspace,
    tab,
    left,
    right,
    up,
    down,
    home,
    end,
    insert,
    delete,
    page_up,
    page_down,
    shift,
    control,
    alt,
    super,
    caps_lock,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    _,

};
