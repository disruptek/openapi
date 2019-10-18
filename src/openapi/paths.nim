import tables
import strutils
import sequtils

import npeg

import foreach

type
  PathTokenKind* = enum ConstantSegment, VariableSegment
  PathToken* = tuple
    kind: PathTokenKind
    value: string
  TemplateParse* = object
    segments*: seq[PathToken]
    path*: string
    ok*: bool

proc `$`*(segment: PathToken): string =
  result = segment.value

proc isTemplate*(path: string): bool =
  ## quickly test to see if the path might be templated
  let
    a = path.find('{')
    b = path.find('}')
  return a < b and a > -1

iterator variables*(parsed: TemplateParse): string =
  foreach segment in parsed.segments.items of PathToken:
    if segment.kind != VariableSegment:
      continue
    yield segment.value

iterator constants*(parsed: TemplateParse): string =
  foreach segment in parsed.segments.items of PathToken:
    if segment.kind != ConstantSegment:
      continue
    yield segment.value

proc parseTemplate*(path: string): TemplateParse =
  ## parse a path and pull out the variable names and constants
  if not path.isTemplate:
    return TemplateParse(ok: false, path: path)
  result = TemplateParse(ok: true, path: path)
  var segments: seq[PathToken]
  let destruct = peg "path":
    noncurly <- Print - '{' - '}'
    text <- +noncurly
    variable <- '{' * >text * '}':
      segments.add (kind: VariableSegment, value: $1)
    segment <- >text | variable:
      if capture.len > 1:
        segments.add (kind: ConstantSegment, value: $1)
    path <- +segment
  var parsed = destruct.match(path)
  if not parsed.ok:
    return TemplateParse(ok: false, path: path)
  result.segments = segments

proc headrest(list: seq[string]):
  tuple[head: string, tail: seq[string]] {.inline.} =
  assert list.len >= 1, "list empty; ran outta items?"
  result = (head: list[0], tail: list[1..^1])

iterator rfind(s: string; p: string; i= -1): int =
  ## yield indices of matches in reverse order
  var index = i
  while index != 0:
    index = s.rfind(p, 0, index)
    if index == -1:
      break
    yield index

proc match*(source: string; path: string;
  constants: seq[string]; variables: seq[string]): bool =
  ## unsatisfied path variables/constants are an error
  var
    head: string
    tail: seq[string]

  # if we have empty source
  if source.len == 0:
    # we're done one way or another
    return path.len == 0

  # if we're looking at a constant segment
  if source[0] != '{':
    (head, tail) = constants.headrest
    assert source.startsWith(head),
      "source `" & source & "` doesn't match section `" & head & "`"
    assert path.startsWith(head),
      "path `" & path & "` doesn't match section `" & head & "`"
    return match(source[head.len..^1], path[head.len..^1], tail, variables)

  # source holds a variable
  (head, tail) = variables.headrest
  head = '{' & head & '}'
  assert source.find(head) == 0, "source doesn't match parse"
  if constants.len == 0:
    # we cannot disambiguate two adjacent variables,
    # but make sure we can associate variable->value
    assert tail.len == 0, "cannot disambiguate multiple variables"
    # it seems that the variable may be empty in some inputs
    #assert path.len > 0, "insufficient input to fill variable"
    # any remaining input is part of the sole remaining variable
    return true
  let (fhead, ftail) = constants.headrest
  discard ftail # noqa
  # greedily attempt to match constants, starting at the back
  foreach i in path.rfind(fhead) of int:
    if match(source[head.len..^1], path[i..^1], constants, tail):
      return true
  assert false, "path doesn't match source variable"
  return false

proc match*(tp: TemplateParse; input: string): bool =
  ## unsatisfied path variables/constants are an error
  var
    constants = toSeq tp.constants
    variables = toSeq tp.variables
  result = tp.path.match(input, constants, variables)

proc composePath*(path: string; variables: Table[string, string]): string =
  ## create a path with variable substitution per the template, variables
  result = path
  foreach key, value in variables.pairs of string and string:
    var token = '{' & key & '}'
    result = result.replace(token, value)
    assert token notin result, "replace didn't replace all instances"
