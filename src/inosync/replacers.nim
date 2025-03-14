import std / [logging, os, strutils, tables, tempfiles]
import std/private/osfiles
import nmark

import misc

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
    outputPath currentSourcePath.parentDir / "../../futhark_poppler.nim"
else:
  include "../../futhark_poppler.nim"

{.experimental: "codeReordering".}

const
  beginMark* = "<!-- INOSYNC BEGIN -->"
  endMark* = "<!-- INOSYNC END -->"
  pictograms = ["unknown", "weightlifting", "biathlon", "modern_pentathlon",
                "fencing", "athletics", "shooting", "cross_country_skiing",
                "swimming", "triathlon"]
  actions* = {
    "kallelse": (repKallelse, "toggle promobox with link to /kallelse.pdf"),
    "styrelse": (repStyrelse, "create table rows from tsv file"),
    "tavlingar": (repTavlingar, "create rows of divs from tsv file"),
    "warn": (repAlertWarn, "toggle warning alert with text from file"),
    "info": (repAlertInfo, "toggle info alert with text from file"),
    "markdown": (repMarkdown, "create html from markdown file"),
    "plain": (repPlain, "get plain text from file"),
  }.toOrderedTable

proc getAction*(name: string): RepProc {.inline.} =
  if actions.hasKey(name):
    result = actions[name][0]
  else:
    quit("unknown action: " & name, 100)

proc getPictogram(sport: string): string =
  case toLower(sport)
  of "atlet", "tyngdlyftning":
    pictograms[1]
  of "biathlon", "skidskytte":
    pictograms[2]
  of "femkamp", "m5k", "modern femkamp", "pentathlon":
    pictograms[3]
  of "fäktning":
    pictograms[4]
  of "löpning":
    pictograms[5]
  of "ol-skytte", "orienteringsskytte":
    pictograms[6]
  of "skidor", "längdskidor":
    pictograms[7]
  of "simning":
    pictograms[8]
  of "triathlon":
    pictograms[9]
  else:
    pictograms[0]

assert pictograms.len >= 10

proc replacer*(wp: ptr WatchPair) {.gcsafe.} =
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
  if getHandlers()[0].levelThreshold == lvlDebug:
    var procName: string
    for k, v in actions:
      if v[0] == wp[].action:
        procName = k
        break
    debug "replacer starting using action: " & procName
  if not open(ofile, $wp[].ofw.path, fmRead):
    warn "could not open ofile: " & $wp[].ofw.path
    return
  try:
    (tfile, tpath) = createTempFile("inosync", "")
    inclFilePermissions(tpath, {fpGroupRead, fpOthersRead})
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
        warn "could not determine section to replace in ofile ($1, $2): $3" % [
            $beginPos, $endPos, $wp[].ofw.path]
        tremove = true
        return

      if not wp[].action(wp[].ifw.path, tfile):
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
  moveFile(tpath, $wp[].ofw.path)

proc repStyrelse*(ifn: string, tfile: File): bool {.gcsafe.} =
  ## Replacer specialized for creating styrelse.html <table> rows.
  ## Enforces 3 fields. 1st field is expected to contain name, and 3rd field
  ## contact information with <br> separation; contact info with '@' creates
  ## mailto link. Rows starting with ';' or '#' are ignored.
  var ifile: File
  if open(ifile, ifn, fmRead):
    var iline: string
    block headers:
      while ifile.readLine(iline):
        if not iline.startsWith("#") and not iline.startsWith(";"):
          let row = "<thead><tr><th>" & iline.replace("\t", "</th><th>") & "</th></tr></thead>"
          tfile.writeLine row
          break headers
    tfile.writeLine "<tbody>"
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
    tfile.writeLine "</tbody>"
    result = true
  else:
    warn "could not open ifile: " & ifn

proc repKallelse*(ifn: string, tfile: File): bool {.gcsafe.} =
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
      warn "failed to load PDF: " & $error.message & ", [" & $ $error.code & "]"
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
    elif desc == "" and ("Mötet " in line or "Härmed" in line):
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
      warn "could not open ifile: " & ifn
      return false
    tfile.write """<div class="alert $1">\n<p class="inner">\n""" % class
    var iline: string
    while ifile.readLine(iline):
      tfile.writeLine iline
    tfile.write """</p>\n</div>\n"""
  return true

proc repAlertWarn*(ifn: string, tfile: File): bool {.gcsafe.} =
  ## Replacer for toggling warning alert.
  repAlert(ifn, tfile, "warning")

proc repAlertInfo*(ifn: string, tfile: File): bool {.gcsafe.} =
  ## Replacer for toggling info alert.
  repAlert(ifn, tfile, "info")

proc repPlain*(ifn: string, tfile: File): bool {.gcsafe.} =
  ## Replacer simply writing lines to file as is.
  var ifile: File
  if open(ifile, ifn, fmRead):
    var iline: string
    while ifile.readLine(iline):
      tfile.writeLine iline
    result = true
  else:
    warn "could not open ifile: " & ifn

proc repMarkdown*(ifn: string, tfile: File): bool {.gcsafe.} =
  ## Replacer creating HTML from markdown and writing it to file.
  var ifile: File
  if open(ifile, ifn, fmRead):
    let md = readAll ifile
    tfile.write markdown(md)
    result = true
  else:
    warn "could not open ifile: " & ifn

proc repTavlingar*(ifn: string, tfile: File): bool {.gcsafe.} =
  ## Replacer specialized for creating tavlingar.html <div> sets.
  ## Enforces 6 fields.
  var ifile: File
  if open(ifile, ifn, fmRead):
    var iline: string
    while ifile.readLine(iline):
      if not iline.startsWith("#") and not iline.startsWith(";") and iline != "":
        var
          fields = iline.split('\t')
        while fields.len < 3:
          fields.add ""
        let
          pic = getPictogram(fields[3])
          item = """
  <div class="competition-row">
    <div>
      <div class="pictogram pg-$7"></div>
      <div>
        <h2><a href="$6" target="_blank">$1</a></h2>
        <span>$2, $3</span>
      </div>
    </div>
    <div>
      <p>
        <b>Sport</b>: $4<br>
        <b>Klasser</b>: $5<br>
        <a href="$6" target="_blank" class="button" title="Gå till extern webbplats">Mer information</a>
      </p>
    </div>
  </div>
""" % [fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], pic]
        tfile.writeLine item
    result = true
  else:
    warn "could not open ifile: " & ifn

const toggles*: array[3, RepProc] = [repKallelse, repAlertWarn, repAlertInfo]
  ## Replacer procs that show or hide content based on if file `ifn` exists.
