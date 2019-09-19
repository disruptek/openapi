import logging
import unittest
import strutils
import options
import json

import paths
import parser
import hydrate


let logger = newConsoleLogger(useStderr=true)
addHandler(logger)


suite "paths":
  let templates = @[
    "{path}", "{mime type}",
    "/{path}", "/path/{path}",
    "/{foo}/{bar}", "{foo}/bif/{bar}",
    "/one/{two}three", "/one/two{three}/four",
  ]
  let nottemplates = @[
    "{path", "}mime type{",
    "/{path", "/path/path}",
    "/foo}/{bar", "foo/bif/bar",
  ]
  let paths = @[
    "anything/really", "application/json",
    "/hello-world", "/path/is/fine/",
    "/some/thing/else", "/its/bif/again/",
    "/one/threethree"
  ]

  setup: discard
  teardown: discard

  test "identify a path template":
    for t in templates:
      check t.isTemplate == true
    for t in nottemplates:
      check t.isTemplate == false

  test "parse a path template":
    var results: seq[tuple[c: string; v: string]]
    var should = @[
      ("", "path"), ("", "mime type"),
      ("/", "path"), ("/path/", "path"),
      ("/,/", "foo,bar"), ("/bif/", "foo,bar"),
      ("/one/,three", "two"), ("/one/two,/four", "three")
    ]
    for t in templates:
      var res = t.parseTemplate
      check res.ok == true
      var constants, variables: seq[string]
      for seg in res.segments:
        if seg.kind == ConstantSegment:
          constants.add $seg
        else:
          variables.add $seg
      results.add (c: constants.join(","), v: variables.join(","))
    check results == should
    for t in nottemplates:
      var res = t.parseTemplate
      check res.ok == false
  test "match a path template":
    var
      src: string
      par: TemplateParse
      res: bool
    for i, pat in paths.pairs:
      src = templates[i]
      par = src.parseTemplate
      res = par.match(pat)
      check res == true

suite "parser":
  let regexp = "^x-"
  let vendors = @["X-bad-case", "x-normal-vendor"]
  let notvendors = @["not-a-vendor", "also_not_a_vendor", "^x-also-not"]

  test "match a regular expression":
    check regexp.isRegExp
    for v in vendors:
      check v.match(regexp) == true
    for v in notvendors:
      check v.match(regexp) == false

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
