import sets
import json
import tables
import strutils
import unicode
import sequtils

when not defined(release):
  import strformat

import spec
import paths

type
  FieldHash* = HashSet[string]
  ParserResult* = ref object
    ok*: bool
    msg*: string
    key*: FieldName
    ftype*: FieldTypeDef
    input*: JsonNode
    child*: ParserResult

proc fail(pr: var ParserResult; msg: string; key: FieldName ="";
  ftype: FieldTypeDef=nil; input: JsonNode=nil): ParserResult =
  result = pr
  result.ok = false
  if input != nil:
    result.input = input
  if msg == "":
    if result.msg == "":
      if pr.child != nil:
        if pr.child.ok == false:
          result.msg = pr.child.msg
  else:
    result.msg = msg
  result.key = key
  if ftype != nil:
    result.ftype = ftype

proc `$`*(pr: ParserResult): string =
  if pr.ok:
    return "parse okay"
  when not defined(release):
    result = &"""
    parse failure
      error: {pr.msg}
      field: {pr.key}
      expected: {pr.ftype}
      input: {pr.input}
    """
    var r = pr.child
    while r != nil:
      result &= "\n" & $r
      r = r.child
  else:
    result = "parse failure"

proc isRegExp*(pattern: string): bool =
  result = pattern.len > 0 and pattern[0] == '^'

proc match*(name: string; pattern: string): bool =
  ## a re-free "re.match" using pure optimism
  if not pattern.isRegExp:
    return false
  let p = pattern[1..^1]
  # many inputs have incorrect case
  # FIXME: warn about this someday
  result = 0 == name.toLower.find(p.toLower)

proc parseField*(ftype: FieldTypeDef; js: JsonNode): ParserResult

proc parsePair(js: JsonNode; name: FieldName;
  ftype: FieldTypeDef; missing: var FieldHash): ParserResult =
  ## validate input given a key/value from a schema
  result = ParserResult(ok: true, input: js, key: name, ftype: ftype, child: nil)
  # identify regex name specifiers
  if ftype.pattern:
    assert not ftype.required, "regexp `" & name & "` required?"
    assert name.isRegexp, "i can't grok `" & name & "` as regexp"
    # examine missing keys from input, and
    for key in missing.toSeq:
      # ignore any that don't match
      if not key.match(name):
        continue
      # matches are no longer missing
      missing.excl key
      # verify that matches parse
      result.child = ftype.parseField(js[key])
      if result.child.ok:
        continue
      # or bomb out
      return result.fail(result.child.msg, key=key, input=js[key])
  # it's not a regexp; is it a template?
  elif name.isTemplate:
    assert not ftype.required, "path template `" & name & "` required?"
    var caught = name.parseTemplate
    if not caught.ok:
      return result.fail("bad template", key=name)
    for key in missing.toSeq:
      # FIXME: are multiple templates ever valid?
      assert caught.match(key), "template doesn't match " & key
      missing.excl key
  # it's not a pattern; is it in input?
  elif name notin js:
    # was it required?
    if ftype.required:
      return result.fail("missing in input")
    # do nothing since we didn't get the name in the input
  else:
    result.child = ftype.parseField(js[name])
    if result.child.ok:
      return
    # or bomb out
    return result.fail(result.child.msg)

proc parsePair*(js: JsonNode; name: FieldName;
  ftype: FieldTypeDef): ParserResult =
  ## convenience
  var missing: FieldHash
  missing.init()
  result = js.parsePair(name, ftype, missing)

proc parseSchema*(schema: Schema; js: JsonNode): ParserResult =
  result = ParserResult(ok: true, input: js)
  var missing: FieldHash

  assert schema.len > 0, "schema appears to be empty"

  if js.kind == JObject and "type" in schema:
    if "type" notin js:
      return result.fail("missing in input", key="type")

  missing.init()
  # first iterate over input, and
  for key, value in js.pairs:
    # note missing fields, or
    if key notin schema:
      missing.incl key
      continue
    # verify that found fields parse, or
    result = schema[key].parseField(value)
    if not result.ok:
      # bomb out because no bueno
      return result.fail(result.msg, key=key)

  # turning to the schema,
  for name, ftype in schema.pairs:
    result = js.parsePair(name, ftype, missing)
    if not result.ok:
      return

  if missing.len > 0:
    return result.fail("unrecognized inputs: " & $missing)

proc parseField*(ftype: FieldTypeDef; js: JsonNode): ParserResult =
  ## parse arbitrary field per arbitrary value definition
  result = ParserResult(ok: true, input: js, ftype: ftype)
  case ftype.kind:
  of Anything: discard
  of Primitive:
    if js.kind notin ftype.kinds:
      return result.fail("bad type", key="?")
  of Complex:
    result = ftype.schema.parseSchema(js)
  of Either:
    result = ftype.a.parseField(js)
    if not result.ok:
      result = ftype.b.parseField(js)
  of List:
    for j in js.elems:
      result = ftype.member.parseField(j)
      if not result.ok:
        break
