when not defined(noseccomp):
  import seccomp
  proc lockdown*() =
    ## Allow only a subset of syscalls.
    let ctx = seccomp_ctx()
    ctx.add_rule(Allow, "brk")                   # change data segment size
    ctx.add_rule(Allow, "access")                # check real user's permissions for file
    ctx.add_rule(Allow, "openat")                # open file relative to directory file descriptor
    ctx.add_rule(Allow, "fstat")                 # file status
    ctx.add_rule(Allow, "mmap")                  # map/unmap files/devices into memory
    ctx.add_rule(Allow, "close")                 # close file descriptor
    ctx.add_rule(Allow, "read")                  # read from file descriptor
    ctx.add_rule(Allow, "pread64")               # read from/write to file descriptor at given offset
    ctx.add_rule(Allow, "set_robust_list")       # get/set list of robust futexes
    ctx.add_rule(Allow, "rseq")
    ctx.add_rule(Allow, "mprotect")              # set protection on region of memory
    ctx.add_rule(Allow, "prlimit64")
    ctx.add_rule(Allow, "munmap")                # map/unmap files/devices into memory
    ctx.add_rule(Allow, "getrandom")
    ctx.add_rule(Allow, "futex")                 # fast user-space locking
    ctx.add_rule(Allow, "ioctl")                 # control device
    ctx.add_rule(Allow, "newfstatat")
    ctx.add_rule(Allow, "inotify_init")          # initialize inotify instance
    ctx.add_rule(Allow, "inotify_init1")         # initialize inotify instance
    ctx.add_rule(Allow, "readlink")              # read value of symbolic link
    ctx.add_rule(Allow, "write")                 # to file descriptor
    ctx.add_rule(Allow, "inotify_add_watch")     # add watch to initialized inotify instance
    ctx.add_rule(Allow, "inotify_rm_watch")      # remove existing watch from inotify instance
    ctx.add_rule(Allow, "fcntl")                 # change file descriptor
    ctx.add_rule(Allow, "lseek")                 # reposition read/write file offset
    ctx.add_rule(Allow, "rename")                # change name/location of file
    ctx.add_rule(Allow, "unlink")                # delete name/possibly file it refers to
    ctx.add_rule(Allow, "gettid")                # thread identification
    ctx.add_rule(Allow, "getpid")                # process identification
    ctx.add_rule(Allow, "open")                  # open/possibly create file/device
    ctx.add_rule(Allow, "rt_sigaction")          # examine/change signal action
    ctx.add_rule(Allow, "rt_sigreturn")          # return from signal handler/cleanup stack frame
    ctx.add_rule(Allow, "rt_sigprocmask")        # examine/change blocked signals
    ctx.add_rule(Allow, "stat")                  # file status
    ctx.add_rule(Allow, "writev")                # read/write data into multiple buffers
    ctx.add_rule(Allow, "lstat")                 # file status
    ctx.add_rule(Allow, "readv")                 # read/write data into multiple buffers
    ctx.add_rule(Allow, "tkill")                 # send signal to thread
    ctx.add_rule(Allow, "tgkill")                # send signal to thread
    ctx.add_rule(Allow, "prctl")                 # operations on process
    ctx.add_rule(Allow, "exit")                  # terminate calling process
    ctx.add_rule(Allow, "exit_group")            # exit all threads in process
    ctx.load()
else:
  proc lockdown*() = discard
