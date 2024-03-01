when not defined(noseccomp):
  import seccomp
  proc lockdown*() =
    ## Allow only a subset of syscalls.
    let ctx = seccomp_ctx()
    ctx.add_rule(Allow, "read")
    ctx.add_rule(Allow, "write")
    ctx.add_rule(Allow, "close")
    ctx.add_rule(Allow, "rename")
    ctx.add_rule(Allow, "unlink")
    ctx.add_rule(Allow, "newfstatat")
    ctx.add_rule(Allow, "exit_group")
    ctx.add_rule(Allow, "inotify_add_watch")
    ctx.add_rule(Allow, "inotify_rm_watch")
    ctx.add_rule(Allow, "openat")
    ctx.add_rule(Allow, "lseek")
    ctx.add_rule(Allow, "getrandom")
    ctx.add_rule(Allow, "fcntl")
    ctx.add_rule(Allow, "rt_sigaction")
    ctx.add_rule(Allow, "rt_sigprocmask")
    ctx.add_rule(Allow, "rt_sigreturn")
    ctx.add_rule(Allow, "tkill")
    # Poppler
    ctx.add_rule(Allow, "fstat")
    ctx.add_rule(Allow, "brk")
    ctx.add_rule(Allow, "mmap")
    ctx.add_rule(Allow, "munmap")
    ctx.add_rule(Allow, "mremap")
    ctx.add_rule(Allow, "mprotect")
    ctx.add_rule(Allow, "getdents64")
    ctx.add_rule(Allow, "pread64")
    ctx.add_rule(Allow, "futex")
    # Alpine Linux
    ctx.add_rule(Allow, "writev")
    ctx.add_rule(Allow, "readv")
    ctx.add_rule(Allow, "open")
    ctx.add_rule(Allow, "ioctl")
    ctx.add_rule(Allow, "lstat")
    ctx.load()
else:
  proc lockdown*() = discard
