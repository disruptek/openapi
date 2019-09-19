import json
import options
import uri

import spec
import paths

type
  KeyVal = tuple[key: string; val: string]
  HydrateInputs = openarray[KeyVal] | JsonNode | seq[KeyVal]

converter toHydrationInputs(input: JsonNode): seq[KeyVal] =
  if input == nil:
    return
  if input.kind != JObject:
    return
  for kv in input.pairs:
    var value: string
    case kv.val.kind:
    of JString:
      value = kv.val.getStr
    of JInt, JFloat, JBool:
      value = $kv.val
    of JNull:
      value = ""
    else:
      raise newException(ValueError, "unable to render " & $kv.val.kind)
    result.add (key: kv.key, val: value)

proc hydratePath(input: openarray[KeyVal]; segments: seq[PathToken]): Option[string] =
  ## reconstitute a path with constants and variable values from an openarray
  var head: string
  if segments.len == 0:
    return some("")
  head = segments[0].value
  case segments[0].kind:
  of ConstantSegment: discard
  of VariableSegment:
    block found:
      for kv in input:
        if head == kv.key:
          head = kv.val
          break found
      return
  var remainder = input.hydratePath(segments[1..^1])
  if remainder.isNone:
    return
  result = some(head & remainder.get)

proc hydrateTemplate*(path: string; values: openarray[KeyVal]): Option[string] =
  ## hydrate an arbitrary string with provided values
  var
    parsed: TemplateParse

  if values.len == 0:
    if path.isTemplate:
      raise newException(ValueError, "values required to populate template")
    return some(path)

  parsed = parseTemplate(path)

  for segment in parsed.segments:
    if segment.kind != VariableSegment:
      continue
    var
      msg = "path template references an unknown variable `" & $segment & "`"
    block found:
      for kv in values:
        if kv.key == $segment:
          break found
      raise newException(ValueError, msg)

  result = hydratePath(values, parsed.segments)

proc hydrateTemplate*(path: string; values: JsonNode): Option[string] =
  ## hydrate an arbitrary string with provided JObject values
  result = hydrateTemplate(path, values.toHydrationInputs)

proc hydrateUri*(uri: Uri; values: HydrateInputs): Option[Uri] =
  ## hydrate a Uri's host and path fields
  var success = uri
  let
    path = hydrateTemplate(uri.path, values)
    host = hydrateTemplate(uri.hostname, values)
  if path.isNone or host.isNone:
    return
  success.path = path.get
  success.hostname = host.get
  result = some(success)
