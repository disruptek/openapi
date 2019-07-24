#? replace(sub = "\t", by = " ")
import logging
import unittest
import strutils

import paths
import parser


let logger = newConsoleLogger(useStderr=true)
addHandler(logger)


suite "paths":
	let templates = @[
		"{path}", "{mime type}",
		"/{path}", "/path/{path}",
		"/{foo}/{bar}", "{foo}/bif/{bar}",
		"/one/{two}three",
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
			("/one/,three", "two")
		]
		for t in templates:
			var res = t.parseTemplate
			check res.ok == true
			results.add (c: res.constants.join(","), v: res.variables.join(","))
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
			res = src.match(pat, par.constants, par.variables)
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
