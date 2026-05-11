/// Koda bytecode opcode definitions.
pub const Op = enum(u8) {
    // Constants / literals
    constant,      // u8 index into chunk.constants
    nil,
    true_,
    false_,
    pop,

    // Arithmetic
    add,
    sub,
    mul,
    div,
    mod,

    // Comparison
    eq,
    ne,
    lt,
    gt,
    le,
    ge,

    // Logic
    and_,
    or_,
    not_,
    neg,

    // Variables
    get_global,    // u8 name-constant index
    set_global,    // u8 name-constant index
    get_local,     // u8 stack slot
    set_local,     // u8 stack slot
    get_upvalue,   // u8 upvalue index
    set_upvalue,   // u8 upvalue index

    // Control flow
    jump,          // u16 offset (big-endian)
    jump_if_false, // u16 offset (big-endian)
    loop,          // u16 back-offset (big-endian)

    // Functions
    call,          // u8 arg count
    return_,
    closure,       // u8 proto-constant index, followed by upvalue descriptors

    // Async
    await_,
    spawn,         // u8 arg count

    // Pipeline
    pipe,

    // Tables
    create_table,
    table_get,
    table_set,

    // Arrays
    create_array,  // u8 element count
    array_get,
    array_set,
    array_append,

    // Range
    make_range,
    iter_next,     // u8 jump offset if exhausted
};
