import json
import options
import uri

import spec
import paths

proc hydratePath(input: JsonNode; segments: seq[PathToken]): Option[string] =
  ## reconstitute a path with constants and variable values taken from json
  var head: string
  if segments.len == 0:
    return some("")
  head = segments[0].value
  case segments[0].kind:
  of ConstantSegment: discard
  of VariableSegment:
    if head notin input:
      return
    let js = input[head]
    case js.kind:
    of JString:
      head = js.getStr
    of JInt, JFloat, JBool:
      head = $js
    of JNull:
      head = ""
    else:
      return
  var remainder = input.hydratePath(segments[1..^1])
  if remainder.isNone:
    return
  result = some(head & remainder.get)

proc hydrateTemplate*(path: string; values: JsonNode): Option[string] =
  ## hydrate an arbitrary string with values from a Json object
  var
    parsed: TemplateParse

  if values == nil or values.kind != JObject:
    if path.isTemplate:
      raise newException(ValueError, "values JObject required to populate template")
    return some(path)

  parsed = parseTemplate(path)

  # add some assertions
  for segment in parsed.segments:
    if segment.kind != VariableSegment:
      continue
    var
      msg = "path template references an unknown variable `" & $segment & "`"
    assert $segment in values, msg

  result = hydratePath(values, parsed.segments)

proc hydrateUri*(uri: Uri; values: JsonNode): Option[Uri] =
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

when isMainModule:
  import unittest

  suite "hydration":
    setup:
      let
        values = %* {
          "region": "us-east-1",
          "a bool": true,
          "an int": 42,
          "none": nil,
        }

    test "hydrate template":
      var wet: Option[string]
      wet = "sqs.{region}.amazonaws.com".hydrateTemplate(values)
      check wet.isSome
      check wet.get == "sqs.us-east-1.amazonaws.com"
      wet = "sqs.{a bool}.amazonaws.com".hydrateTemplate(values)
      check wet.isSome
      check wet.get == "sqs.true.amazonaws.com"
      wet = "sqs.{an int}.amazonaws.com".hydrateTemplate(values)
      check wet.isSome
      check wet.get == "sqs.42.amazonaws.com"
      wet = "sqs.{none}.amazonaws.com".hydrateTemplate(values)
      check wet.isSome
      check wet.get == "sqs..amazonaws.com"
      wet = "sqs.{none}{an int}.{a bool}.amazonaws.com".hydrateTemplate(values)
      check wet.isSome
      check wet.get == "sqs.42.true.amazonaws.com"
