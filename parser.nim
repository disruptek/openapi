#? replace(sub = "\t", by = " ")
import sets
import json
import re
import tables

when not defined(release):
	import strformat

import spec
from paths import isTemplate, parseTemplate

type
	FieldHash* = HashSet[string]
	ParserResult* = object
		ok*: bool
		msg*: string
		key*: FieldName
		ftype*: FieldTypeDef
		input*: JsonNode

proc fail(pr: var ParserResult; msg: string; key: FieldName ="";
	ftype: FieldTypeDef=nil; input: JsonNode=nil): ParserResult =
	result = pr
	result.ok = false
	if input != nil:
		result.input = input
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
			expected: {$pr.ftype}
			input: {$pr.input}
		"""
	else:
		result = "parse failure"

proc parseField(ftype: FieldTypeDef; js: JsonNode): ParserResult

proc parsePair(js: JsonNode; name: FieldName;
	ftype: FieldTypeDef; missing: var FieldHash): ParserResult =
	## validate input given a key/value from a schema
	result = ParserResult(ok: true, input: js, key: name, ftype: ftype)
	# identify regex name specifiers
	if ftype.pattern:
		var rex = re(name, {reIgnoreCase})
		# examine missing keys from input, and
		for key in missing:
			# ignore any that don't match
			if not key.match(rex):
				continue
			# matches are no longer missing
			missing.excl key
			# verify that matches parse
			var pf = ftype.parseField(js[key])
			if pf.ok:
				continue
			# or bomb out
			return result.fail(pf.msg, key=key, input=js[key])
		for key in missing:
			if not key.isTemplate:
				continue
			var caught = key.parseTemplate
			if caught.len == 0:
				return result.fail("bad template", key=key, input=js[key])
	# it's not a pattern; is it in input?
	elif name notin js:
		# was it required?
		if ftype.required:
			return result.fail("missing in input")

proc parseSchema*(schema: Schema; js: JsonNode): ParserResult =
	result = ParserResult(ok: true, input: js)
	var missing: FieldHash
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

proc parseField(ftype: FieldTypeDef; js: JsonNode): ParserResult =
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
