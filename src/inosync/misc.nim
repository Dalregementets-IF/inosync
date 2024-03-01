import std/inotify

const
  beginMark* = "<!-- INOSYNC BEGIN -->"
  endMark* = "<!-- INOSYNC END -->"

proc toString*(event: uint32): string =
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

template debug*(msg: string) =
  when not defined(release):
    echo msg
