// Minimal OpenGL bindings for direct GL calls (bypassing GLAD context).
// The system GL library is already linked via build.zig.

pub const GL_COLOR_BUFFER_BIT: c_uint = 0x00004000;

pub extern "GL" fn glClearColor(red: f32, green: f32, blue: f32, alpha: f32) void;
pub extern "GL" fn glClear(mask: c_uint) void;
