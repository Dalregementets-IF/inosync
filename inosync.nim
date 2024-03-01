import std / [inotify, intsets, parseopt, paths, posix, strutils, tables,
              tempfiles]
import std/private/osfiles
import nmark

{.passL: "`pkg-config --libs poppler-glib`".}
when defined(useFuthark) or defined(useFutharkForPoppler):
  import os
  import futhark
  importc:
    path "/usr/include/poppler"
    path "/usr/include/glib-2.0"
    compilerarg "`pkg-config --cflags poppler-glib`"
    "poppler.h"
    "glib.h"
    outputPath currentSourcePath.parentDir / "futhark_poppler.nim"
else:
  include "futhark_poppler.nim"

const
  watchMaskFile = IN_MODIFY or IN_DELETE_SELF or IN_MOVE_SELF
  watchMaskDir = IN_CREATE or IN_MOVED_TO
  beginMark = "<!-- INOSYNC BEGIN -->"
  endMark = "<!-- INOSYNC END -->"

type
  RepProc = proc (ifn: string, tfile: File): bool {.gcsafe, nimcall.}
  WatchPair = object
    ifw: tuple[name: string, wd: FileHandle = -1]
    ofw: tuple[name: string, wd: FileHandle = -1]
    action: RepProc
  WatchDir = object
    wd: FileHandle = -1
    misses: int  ## counter for unwatched files in the directory
  WatchList = object
    fd: cint                     ## inotify
    pairs: seq[WatchPair]
    map: Table[FileHandle, int]  ## wd to pairs index
    incomplete: IntSet           ## incomplete pairs (has unwatched file)
    queue: IntSet                ## pairs that are ready to receive work
    dirs: Table[string, WatchDir]

var errno {.importc, header: "<errno.h>".}: int

proc parentDir(path: string): string = string(parentDir(Path(path)))

when not defined(noseccomp):
  import seccomp
  proc lockdown() =
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

proc toString(event: uint32): string =
  case event
  of IN_ACCESS: "IN_ACCESS"
  of IN_MODIFY: "IN_MODIFY"
  of IN_ATTRIB: "IN_ATTRIB"
  of IN_CLOSE_WRITE: "IN_CLOSE_WRITE"
  of IN_CLOSE_NOWRITE: "IN_CLOSE_NOWRITE"
  of IN_OPEN: "IN_OPEN"
  of IN_MOVED_FROM: "IN_MOVED_FROM"
  of IN_MOVED_TO: "IN_MOVED_TO"
  of IN_CREATE: "IN_CREATE"
  of IN_DELETE: "IN_DELETE"
  of IN_DELETE_SELF: "IN_DELETE_SELF"
  of IN_MOVE_SELF: "IN_MOVE_SELF"
  of IN_ISDIR: "IN_ISDIR"
  of IN_UNMOUNT: "IN_UNMOUNT"
  of IN_Q_OVERFLOW: "IN_Q_OVERFLOW"
  of IN_IGNORED: "IN_IGNORED"
  else: "UNKNOWN[" & $event & "]"

template debug(msg: string) =
  when not defined(release):
    echo msg

proc newWatchList(): WatchList =
  result.fd = inotify_init()
  if result.fd < 0:
    quit("inotify_init failed, errno: " & $errno, errno)

proc add(wl: var WatchList, infile, outfile: string, action: RepProc) =
  wl.pairs.add WatchPair(ifw: (name: infile, wd: -1),
                         ofw: (name: outfile, wd: -1),
                         action: action)
  wl.incomplete.incl wl.pairs.high
  for fw in [wl.pairs[^1].ifw, wl.pairs[^1].ofw]:
    let dir = parentDir(fw.name)
    if not wl.dirs.hasKey(dir):
      wl.dirs[dir] = WatchDir(wd: -1, misses: 0)
    inc wl.dirs[dir].misses

proc replacer(ifn, ofn: string, repFunc: RepProc) {.gcsafe.} =
  ## Replace data in file.
  ##
  ## `ifn`: source file.
  ## `ofn`: file to replace data in.
  ## `repFunc`: proc implementing the logic for replacement, `tfile` is a
  ##   temporary file for the new `ofn` data.
  var
    tfile, ofile: File
    tpath: string
    tremove: bool
  if not open(ofile, $ofn, fmRead):
    debug "could not open ofile: " & $ofn
    return
  try:
    (tfile, tpath) = createTempFile("inosync", "")
    try:
      var
        oline: string
        beginPos, endPos: int64 = -1
      while ofile.readLine(oline):
        tfile.writeLine oline
        if beginMark in oline:
          beginPos = ofile.getFilePos
          break
      while ofile.readLine(oline):
        if endMark in oline:
          endPos = ofile.getFilePos
          break

      if beginPos < 0 or endPos < 0:
        debug "could not determine section to replace in ofile ($1, $2): $3" % [
            $beginPos, $endPos, $ofn]
        tremove = true
        return

      if not repFunc(ifn, tfile):
        return

      tfile.writeLine oline
      while ofile.readLine(oline):
        tfile.writeLine oline
    finally:
      close tfile
      if tremove:
        removeFile tpath
  finally:
    close ofile
  moveFile(tpath, $ofn)

proc watch(wl: var WatchList) =
  ## Attempt to add inotify watch on any unwatched files and the dirs of any
  ## unwatched files. Any pair that becomes watch complete is added to queue.
  ## Watch on dir is removed if all tracked files inside are watched.
  var completed: IntSet
  for i in wl.incomplete.items:
    for fw in [addr wl.pairs[i].ifw, addr wl.pairs[i].ofw]:
      debug "processing watch on incomplete[" & $i & "]: " & $fw.name
      if fw.wd < 0:
        fw.wd = inotify_add_watch(wl.fd, cstring(fw.name), watchMaskFile)
        if fw.wd >= 0:
          debug "new watch: " & $fw.name & ", " & $fw.wd
          wl.map[fw.wd] = i
          dec wl.dirs[parentDir(fw.name)].misses
        else:
          debug "could not watch: " & $fw.name & ", " & $fw.wd & ", errno: " & $errno
      else:
        debug "already watching: " & $fw.name & ", " & $fw.wd
      if wl.pairs[i].ifw.wd >= 0 and wl.pairs[i].ofw.wd >= 0:
        completed.incl i
  wl.queue = union(wl.queue, completed)
  wl.incomplete = difference(wl.incomplete, completed)
  for k in wl.dirs.keys:
    if wl.dirs[k].wd < 0 and wl.dirs[k].misses > 0:
      wl.dirs[k].wd = inotify_add_watch(wl.fd, cstring(k), watchMaskDir)
      if wl.dirs[k].wd == -1:
        quit("inotify_add_watch failed on directory: " & k & ", errno: " & $errno, errno)
      debug "new watch on dir: " & k
    elif wl.dirs[k].wd >= 0 and wl.dirs[k].misses <= 0:
      if inotify_rm_watch(wl.fd, wl.dirs[k].wd) < 0:
        quit("could not remove watch on directory: " & k & ", errno: " & $errno, errno)
      else:
        debug "removed watch on directory: " & k & ", " & $wl.dirs[k].misses
        wl.dirs[k].wd = -1

proc purge(wl: var WatchList, wd: FileHandle) =
  ## Remove `wd` from tracking and start tracking dir events. Use when the file
  ## targeted by `wd` has been deleted or moved.
  var dir: string
  let i = wl.map[wd]
  for fw in [addr wl.pairs[i].ifw, addr wl.pairs[i].ofw]:
    if fw.wd == wd:
      fw.wd = -1
      dir = parentDir(fw.name)
      debug "purged: " & $fw.name & ", " & $wd
      break
  wl.map.del wd
  wl.incomplete.incl i
  wl.queue.excl i
  inc wl.dirs[dir].misses
  if wl.dirs[dir].wd < 0:
    wl.dirs[dir].wd = inotify_add_watch(wl.fd, cstring(dir), IN_CREATE)
    if wl.dirs[dir].wd == -1:
      quit("inotify_add_watch failed on directory: " & dir & ", errno: " & $errno, errno)
    debug "added watch on directory: " & dir

proc mute(wl: var WatchList, i: int) =
  ## Remove inotify watch on wd pair `i` temporarily. Does not affect queue.
  for fw in [addr wl.pairs[i].ifw, addr wl.pairs[i].ofw]:
    discard inotify_rm_watch(wl.fd, fw.wd)
    debug "muted: " & $fw.name & ", " & $fw.wd
    wl.map.del fw.wd
    fw.wd = -1
    wl.incomplete.excl i

proc unmute(wl: var WatchList, i: int) =
  ## Reinstate inotify watch on muted wd pair `i`. Does not affect queue.
  for fw in [addr wl.pairs[i].ifw, addr wl.pairs[i].ofw]:
    fw.wd = inotify_add_watch(wl.fd, cstring(fw.name), watchMaskFile)
    if fw.wd >= 0:
      debug "unmuted: " & $fw.name & ", " & $fw.wd
      wl.map[fw.wd] = i
    else:
      debug "failed to unmute: " & $fw.name & ", " & $fw.wd & ", errno: " & $errno
  if wl.pairs[i].ifw.wd < 0 or wl.pairs[i].ofw.wd < 0:
    wl.incomplete.incl i

proc processQueue(wl: var WatchList) =
  ## Execute registered action for any pair in queue.
  for i in wl.queue:
    wl.mute i
    debug "processQueue: " & $wl.pairs[i].ifw.name & "->" & $wl.pairs[i].ofw.name
    replacer(wl.pairs[i].ifw.name, wl.pairs[i].ofw.name, wl.pairs[i].action)
    wl.unmute i
  clear wl.queue

proc name(wl: WatchList, wd: FileHandle): string =
  ## Get filename associated with `wd`.
  if wl.map.hasKey(wd):
    let i = wl.map[wd]
    for fw in [addr wl.pairs[i].ifw, addr wl.pairs[i].ofw]:
      if fw.wd == wd:
        return $fw.name
  else: result = "unknown"

proc repStyrelse(ifn: string, tfile: File): bool {.gcsafe.} =
  ## Replacer specialized for creating styrelse.html <table> rows.
  ## Enforces 3 fields. 1st field is expected to contain name, and 3rd field
  ## contact information with <br> separation; contact info with '@' creates
  ## mailto link. Rows starting with ';' or '#' are ignored.
  var ifile: File
  if not open(ifile, ifn, fmRead):
    debug "could not open ifile: " & ifn
    return false
  var iline: string
  block headers:
    while ifile.readLine(iline):
      if not iline.startsWith("#") and not iline.startsWith(";"):
        let row = "<tr><th>" & iline.replace("\t", "</th><th>") & "</th></tr>"
        tfile.writeLine row
        break headers
  while ifile.readLine(iline):
    if not iline.startsWith("#") and not iline.startsWith(";"):
      var
        fields = iline.split('\t')
        tmp: seq[string]
      while fields.len < 3:
        fields.add ""
      for part in fields[2].split("<br>"):
        if '@' in part:
          tmp.add "<a href=\"mailto:$1\" title=\"Mejla $2\">$1</a>" % [part, fields[0]]
        else:
          tmp.add part
      fields[2] = tmp.join("<br>")
      let row = "<tr><td>" & fields[0..2].join("</td><td>") & "</td></tr>"
      tfile.writeLine row
  return true

proc repKallelse(ifn: string, tfile: File): bool {.gcsafe.} =
  ## Replacer specialized for toggling promobox <div> with link to 'kallelse.pdf'
  const
    dTitle = "Dags för årsmöte!"
    dDesc = "Läs kallelsen och anmäl dig nu!"
  var
    error: ptr structgerror
    doc = popplerdocumentnewfromfile(cstring("file:" & ifn), cstring(""), addr error)
  if doc.isNil:
    # `PDF document is damaged` also falls under G_FILE_ERROR_NOENT (code 4)
    # but missing file is expected.
    if error.code != 4 and error.message != "No such file or directory":
      echo "failed to load PDF: " & $error.message & ", [" & $ $error.code & "]"
    gerrorfree(error)
    return true
  defer: gobjectunref(doc)

  var page = poppler_document_get_page(doc, 0)
  defer: gobjectunref(page)
  var
    title, desc: string
    text = popplerpagegettext(page)
  defer: gfree(text)
  for line in split($text, '\n'):
    if title == "" and "Kallelse" in line:
      title = line
    elif desc == "" and "Mötet" in line:
      desc = line
    if title != "" and desc != "":
      break
  let html = """
<div id="interface_promobox_widget-2" class="widget widget_promotional_bar clearfix">
  <div class="promotional-text">$1<span>$2</span>
  </div>
  <a class="call-to-action" href="/kallelse.pdf" title="Läs kallelsen">Se kallelse</a>
</div>
""" % [if title != "": title else: dTitle, if desc != "": desc else: dDesc]
  tfile.write html
  return true

proc repAlert(ifn: string, tfile: File, class: string): bool {.gcsafe.} =
  if fileExists(ifn):
    var ifile: File
    if not open(ifile, ifn, fmRead):
      debug "could not open ifile: " & ifn
      return false
    tfile.write """<div class="alert $1">\n<p class="inner">\n""" % class
    var iline: string
    while ifile.readLine(iline):
      tfile.writeLine iline
    tfile.write """</p>\n</div>\n"""
  return true

proc repAlertWarn(ifn: string, tfile: File): bool {.gcsafe.} =
  ## Replacer for toggling warning alert.
  repAlert(ifn, tfile, "warning")

proc repAlertInfo(ifn: string, tfile: File): bool {.gcsafe.} =
  ## Replacer for toggling info alert.
  repAlert(ifn, tfile, "info")

proc repPlain(ifn: string, tfile: File): bool {.gcsafe.} =
  ## Replacer simply writing lines to file as is.
  if fileExists(ifn):
    var ifile: File
    if not open(ifile, ifn, fmRead):
      debug "could not open ifile: " & ifn
      return false
    var iline: string
    while ifile.readLine(iline):
      tfile.writeLine iline
  return true

proc repMarkdown(ifn: string, tfile: File): bool {.gcsafe.} =
  ## Replacer creating HTML from markdown and writing it to file.
  if fileExists(ifn):
    var ifile: File
    if not open(ifile, ifn, fmRead):
      debug "could not open ifile: " & ifn
      return false
    let md = readAll ifile
    tfile.write markdown(md)
  return true

var argsets: seq[(string, string, RepProc)]
const toggles: array[3, RepProc] = [repKallelse,repAlertWarn,repAlertInfo]
  ## Replacer procs that show or hide content based on if file `ifn` exists.

proc main() =
  var wl = newWatchList()
  for p in argsets.items:
    debug "adding: " & $p[0] & "->" & $p[1]
    wl.add(p[0], p[1], p[2])
  `=destroy`(argsets)
  debug $wl

  when not defined(noseccomp):
    lockdown()
  watch wl
  for i in 0..wl.pairs.high:
    # Process toggle-types even if pair is incomplete
    if wl.pairs[i].action in toggles:
      if wl.pairs[i].ofw.wd >= 0:
        wl.queue.incl i
      break
  processQueue wl
  var evs = newSeq[byte](8192)
  while (let n = read(wl.fd, evs[0].addr, 8192); n) > 0:
    for e in inotify_events(evs[0].addr, n):
      if e[].mask == IN_IGNORED:
        continue
      debug "file: " & wl.name(e[].wd) & ", mask: " & e[].mask.toString
      if e[].wd in wl.map:
        if e[].mask == IN_MODIFY:
          let i = wl.map[e[].wd]
          if i notin wl.incomplete:
            wl.queue.incl i
          elif wl.pairs[i].ofw.wd >= 0 and wl.pairs[i].action in toggles:
            wl.queue.incl i
          processQueue wl
        elif e[].mask == IN_DELETE_SELF or e[].mask == IN_MOVE_SELF:
          let i = wl.map[e[].wd]
          wl.purge e[].wd
          watch wl
          if wl.pairs[i].ofw.wd >= 0 and wl.pairs[i].action in toggles:
            wl.queue.incl i
          processQueue wl
      elif e[].mask == IN_CREATE or e[].mask == IN_MOVED_TO or e[].mask == IN_MOVE_SELF:
        watch(wl)
        processQueue wl
    debug $wl

const
  progName = "inosync"
  progUse = progName & " [-h][-v][-l] [action,path,path ..]"
  progHelp = progUse & "\n" & """
  -l  list available actions
  -h  show this help
  -v  show version"""
  progVer {.strdefine.} = strip(gorge("git tag -l --sort=version:refname '*.*.*' | tail -n1"))
  gitHash {.strdefine.} = strip(gorge("git log -n 1 --format=%H"))
  gitDirty {.strdefine.} = gorge("git status --porcelain --untracked-files=no")
  actions = {
    "kallelse": (repKallelse, "toggle promobox with link to /kallelse.pdf"),
    "styrelse": (repStyrelse, "create table rows from tsv file"),
    "warn": (repAlertWarn, "toggle warning alert with text from file"),
    "info": (repAlertInfo, "toggle info alert with text from file"),
    "markdown": (repMarkdown, "create html from markdown file"),
    "plain": (repPlain, "get plain text from file"),
  }.toTable

proc getAction(name: string): RepProc {.inline.} =
  if actions.hasKey(name):
    result = actions[name][0]
  else:
    quit("unknown action: " & name, 100)

proc printVer*() {.inline.} =
  ## Print version information and exit.
  let dirty =
    if gitDirty != "":
      " (dirty)\n" & gitDirty
    else:
      ""
  quit("""$1 $2
Compiled at $3 $4
Written by Tobias Dély

git hash: $5$6""" % [progName, progVer, CompileDate, CompileTime, gitHash, dirty], QuitSuccess)

when isMainModule:
  var p = initOptParser()
  while true:
    next p
    case p.kind
    of cmdEnd:
      if argsets.len < 1:
        quit("nothing to do", QuitSuccess)
      main()
      break
    of cmdShortOption:
      case p.key:
      of "h":
        quit(progHelp, QuitSuccess)
      of "v":
        printVer()
      of "l":
        var x: seq[string]
        for k, v in actions.pairs:
          x.add k & ": " & v[1]
        quit("available actions:\n" & x.join("\n"), QuitSuccess)
      else:
        quit(progUse, EPERM)
    of cmdArgument:
      let x = p.key.split(',')
      if x.len != 3:
        quit("arguments must be in format '<action>,<path>,<path>' with exactly two ','", 100)
      let act = getAction(x[0])
      argsets.add (x[1], x[2], act)
    else:
      quit(progUse, EPERM)
