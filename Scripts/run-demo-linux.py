"""Run the synthetic UI with local Unix sockets and without Internet sockets."""
import ctypes
import ctypes.util
import errno
import os
import socket
import sys

# libseccomp translates syscall numbers for the running architecture. Filtering socket()
# leaves inherited Wayland/X11 and Vulkan access available to the renderer.
class Argument(ctypes.Structure):
    _fields_ = [("index", ctypes.c_uint), ("comparison", ctypes.c_int),
                ("value", ctypes.c_uint64), ("mask", ctypes.c_uint64)]

lib = ctypes.CDLL(ctypes.util.find_library("seccomp") or "libseccomp.so.2")
lib.seccomp_init.argtypes = [ctypes.c_uint32]
lib.seccomp_init.restype = ctypes.c_void_p
lib.seccomp_rule_add_array.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int,
                                       ctypes.c_uint, ctypes.POINTER(Argument)]
lib.seccomp_load.argtypes = [ctypes.c_void_p]
lib.seccomp_release.argtypes = [ctypes.c_void_p]
lib.seccomp_syscall_resolve_name.argtypes = [ctypes.c_char_p]
ctx = lib.seccomp_init(0x7fff0000)  # SCMP_ACT_ALLOW
if not ctx:
    raise SystemExit("Cannot create the synthetic network sandbox")
try:
    local_only = Argument(0, 1, socket.AF_UNIX, 0)  # SCMP_CMP_NE
    number = lib.seccomp_syscall_resolve_name(b"socket")
    if number < 0 or lib.seccomp_rule_add_array(
            ctx, 0x00050000 | errno.EACCES, number, 1, ctypes.byref(local_only)) != 0:
        raise SystemExit("Cannot configure the synthetic network sandbox")
    if lib.seccomp_load(ctx) != 0:
        raise SystemExit("Cannot enter the synthetic network sandbox")
finally:
    lib.seccomp_release(ctx)
os.execv(sys.argv[1], sys.argv[1:])
