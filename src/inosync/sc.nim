when not defined(noseccomp):
  import seccomp
  proc lockdown*() =
    ## Allow only a subset of syscalls.
    let ctx = seccomp_ctx()
    ctx.add_rule(Allow, "arch_prctl")
    ctx.add_rule(Allow, "set_tid_address")
    ctx.add_rule(Allow, "brk")
    ctx.add_rule(Allow, "mmap")
    ctx.add_rule(Allow, "open")
    ctx.add_rule(Allow, "fcntl")
    ctx.add_rule(Allow, "fstat")
    ctx.add_rule(Allow, "read")
    ctx.add_rule(Allow, "close")
    ctx.add_rule(Allow, "mprotect")
    ctx.add_rule(Allow, "futex")
    ctx.add_rule(Allow, "munmap")
    ctx.add_rule(Allow, "rt_sigprocmask")
    ctx.add_rule(Allow, "rt_sigaction")
    ctx.add_rule(Allow, "inotify_init1")
    ctx.add_rule(Allow, "inotify_add_watch")
    ctx.add_rule(Allow, "inotify_rm_watch")
    ctx.add_rule(Allow, "getrandom")
    ctx.add_rule(Allow, "ioctl")
    ctx.add_rule(Allow, "writev")
    ctx.add_rule(Allow, "lseek")
    ctx.add_rule(Allow, "pread64")
    ctx.add_rule(Allow, "rename")
    ctx.add_rule(Allow, "lstat")
    ctx.add_rule(Allow, "readv")
    ctx.add_rule(Allow, "unlink")
    ctx.add_rule(Allow, "stat")
    ctx.add_rule(Allow, "tkill")
    ctx.add_rule(Allow, "rt_sigreturn")
    ctx.add_rule(Allow, "access")
    ctx.add_rule(Allow, "openat")
    ctx.add_rule(Allow, "set_robust_list")
    ctx.add_rule(Allow, "rseq")
    ctx.add_rule(Allow, "prlimit64")
    ctx.add_rule(Allow, "inotify_init")
    ctx.add_rule(Allow, "write")
    ctx.add_rule(Allow, "getdents64")
    ctx.add_rule(Allow, "newfstatat")
    ctx.add_rule(Allow, "gettid")
    ctx.add_rule(Allow, "getpid")
    ctx.add_rule(Allow, "tgkill")
    ctx.load()
else:
  proc lockdown*() = discard
