"""Render and read one offscreen pixel with existing EGL/GLES libraries.

No window, sound, input capture or library installation. A successful software
renderer is reported separately; it does not validate a physical GPU.
"""

import ctypes as C
import json


def render_pixel():
    egl, gl = C.CDLL("libEGL.so.1"), C.CDLL("libGLESv2.so.2")
    ptr, integer = C.c_void_p, C.c_int

    def bind(lib, name, result, *args):
        function = getattr(lib, name)
        function.restype, function.argtypes = result, args
        return function

    get_display = bind(egl, "eglGetPlatformDisplay", ptr, C.c_uint, ptr, C.POINTER(C.c_ssize_t))
    initialize = bind(egl, "eglInitialize", C.c_uint, ptr, C.POINTER(integer), C.POINTER(integer))
    choose = bind(egl, "eglChooseConfig", C.c_uint, ptr, C.POINTER(integer), C.POINTER(ptr), integer, C.POINTER(integer))
    bind_api = bind(egl, "eglBindAPI", C.c_uint, C.c_uint)
    surface_create = bind(egl, "eglCreatePbufferSurface", ptr, ptr, ptr, C.POINTER(integer))
    context_create = bind(egl, "eglCreateContext", ptr, ptr, ptr, ptr, C.POINTER(integer))
    make_current = bind(egl, "eglMakeCurrent", C.c_uint, ptr, ptr, ptr, ptr)
    surface_destroy = bind(egl, "eglDestroySurface", C.c_uint, ptr, ptr)
    context_destroy = bind(egl, "eglDestroyContext", C.c_uint, ptr, ptr)
    terminate = bind(egl, "eglTerminate", C.c_uint, ptr)
    get_error = bind(egl, "eglGetError", C.c_uint)
    get_string = bind(gl, "glGetString", C.c_char_p, C.c_uint)
    clear_color = bind(gl, "glClearColor", None, C.c_float, C.c_float, C.c_float, C.c_float)
    clear = bind(gl, "glClear", None, C.c_uint)
    read_pixels = bind(gl, "glReadPixels", None, integer, integer, integer, integer, C.c_uint, C.c_uint, ptr)
    gl_error = bind(gl, "glGetError", C.c_uint)
    display = get_display(0x31DD, None, None)  # EGL_PLATFORM_SURFACELESS_MESA
    surface = context = None
    initialized = False

    def unavailable(stage):
        return {"status": "unavailable", "stage": stage, "egl_error": hex(get_error())}

    try:
        major, minor = integer(), integer()
        if not display or not initialize(display, C.byref(major), C.byref(minor)):
            return unavailable("initialize")
        initialized = True
        # Pbuffer, OpenGL ES 2, RGB 8-bit; terminating sentinel EGL_NONE.
        attributes = (integer * 13)(0x3033, 1, 0x3040, 4, 0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, 0x3038)
        config, count = ptr(), integer()
        if not choose(display, attributes, C.byref(config), 1, C.byref(count)) or count.value < 1:
            return unavailable("choose_config")
        if not bind_api(0x30A0):  # EGL_OPENGL_ES_API
            return unavailable("bind_api")
        surface = surface_create(display, config, (integer * 5)(0x3057, 1, 0x3056, 1, 0x3038))
        context = context_create(display, config, None, (integer * 3)(0x3098, 2, 0x3038))
        if not surface or not context or not make_current(display, surface, surface, context):
            return unavailable("make_current")
        raw_renderer = get_string(0x1F01)  # GL_RENDERER
        if not raw_renderer:
            return unavailable("renderer")
        renderer = raw_renderer.decode("utf-8", "replace")[:256]
        clear_color(1, 0, 0, 1)
        clear(0x4000)  # GL_COLOR_BUFFER_BIT
        pixel = (C.c_ubyte * 4)()
        read_pixels(0, 0, 1, 1, 0x1908, 0x1401, pixel)
        error = gl_error()
        passed = error == 0 and list(pixel) == [255, 0, 0, 255]
        software = any(name in renderer.lower() for name in ("llvmpipe", "softpipe", "swrast", "software", "swiftshader"))
        return {"status": "passed" if passed else "failed", "renderer": renderer,
                "software": software, "pixel": list(pixel), "gl_error": error,
                "egl_version": f"{major.value}.{minor.value}"}
    finally:
        if initialized:
            make_current(display, None, None, None)
            if context:
                context_destroy(display, context)
            if surface:
                surface_destroy(display, surface)
            terminate(display)


if __name__ == "__main__":
    try:
        result = render_pixel()
    except (OSError, AttributeError):
        result = {"status": "unavailable", "stage": "libraries_or_entrypoints"}
    print(json.dumps(result, allow_nan=False))
