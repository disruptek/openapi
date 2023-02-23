import std/strutils
import std/options
import std/json

import pkg/openapi/paths
import pkg/openapi/parser
import pkg/openapi/hydrate


const
  templates = @[
    "{path}", "{mime type}",
    "/{path}", "/path/{path}",
    "/{foo}/{bar}", "{foo}/bif/{bar}",
    "/one/{two}three", "/one/two{three}/four",
  ]
  nottemplates = @[
    "{path", "}mime type{",
    "/{path", "/path/path}",
    "/foo}/{bar", "foo/bif/bar",
  ]
  somepaths = @[
    "anything/really", "application/json",
    "/hello-world", "/path/is/fine/",
    "/some/thing/else", "/its/bif/again/",
    "/one/threethree"
  ]
  regexp = "^x-"
  vendors = @["X-bad-case", "x-normal-vendor"]
  notvendors = @["not-a-vendor", "also_not_a_vendor", "^x-also-not"]

static:
  let values = %* {
    "region": "us-east-1",
    "a bool": true,
    "an int": 42,
    "none": nil,
  }
  echo "identify a path template"
  for t in templates:
    assert t.isTemplate == true
  for t in nottemplates:
    assert t.isTemplate == false

  echo "parse a path template"
  var results: seq[tuple[c: string; v: string]]
  var should = @[
    ("", "path"), ("", "mime type"),
    ("/", "path"), ("/path/", "path"),
    ("/,/", "foo,bar"), ("/bif/", "foo,bar"),
    ("/one/,three", "two"), ("/one/two,/four", "three")
  ]
  for t in templates:
    var res = t.parseTemplate
    assert res.ok == true
    var constants, variables: seq[string]
    block compile_time_loop_definition_broken_in_nim_maybe:
      constants = @[]
      variables = @[]
    for seg in res.segments:
      if seg.kind == ConstantSegment:
        constants.add $seg
      else:
        variables.add $seg
    results.add (c: constants.join(","), v: variables.join(","))
  for i in 0 ..< should.len:
    assert results[i].c == should[i][0],
      should[i].repr & " != " & results[i].repr
    assert results[i].v == should[i][1],
      should[i].repr & " != " & results[i].repr
  for t in nottemplates:
    var res = t.parseTemplate
    assert res.ok == false

  echo "match a path template"
  var
    src: string
    par: TemplateParse
    res: bool
  for i, pat in somepaths.pairs:
    src = templates[i]
    par = src.parseTemplate
    res = par.match(pat)
    assert res == true

  echo "match a regular expression"
  assert regexp.isRegExp
  for v in vendors:
    assert v.match(regexp) == true
  for v in notvendors:
    assert v.match(regexp) == false

  echo "hydrate template"
  var wet: Option[string]
  wet = "sqs.{region}.amazonaws.com".hydrateTemplate(values)
  assert wet.isSome
  assert wet.get == "sqs.us-east-1.amazonaws.com"
  wet = "sqs.{a bool}.amazonaws.com".hydrateTemplate(values)
  assert wet.isSome
  assert wet.get == "sqs.true.amazonaws.com"
  wet = "sqs.{an int}.amazonaws.com".hydrateTemplate(values)
  assert wet.isSome
  assert wet.get == "sqs.42.amazonaws.com"
  wet = "sqs.{none}.amazonaws.com".hydrateTemplate(values)
  assert wet.isSome
  assert wet.get == "sqs..amazonaws.com"
  wet = "sqs.{none}{an int}.{a bool}.amazonaws.com".hydrateTemplate(values)
  assert wet.isSome
  assert wet.get == "sqs.42.true.amazonaws.com"
