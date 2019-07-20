#? replace(sub = "\t", by = " ")
import os
import json
import times
import re
import streams

# critical for, uh, reasons
import tables

import spec
from schema2 import OpenApi2

proc parseField(ftype: FieldTypeDef; js: JsonNode): bool

proc parseSchema(schema: Schema; js: JsonNode): bool =
	if js.kind == JObject and "type" in schema:
		if "type" notin js:
			echo "missing type in input: " & $js
			return false
	var missing: seq[string] = @[]
	for key, value in js.pairs:
		if key notin schema:
			missing.add key
			continue
		var ftype = schema[key]
		if ftype.parseField(value):
			echo key, " ok"
			continue
		echo "parse failure for field ", key
		return false
	for pattern, ftype in schema.pairs:
		if ftype.pattern:
			var rex = re(pattern, {reIgnoreCase})
			for key in missing:
				if not key.match(rex):
					continue
				if ftype.parseField(js[key]):
					break
				echo "parse failure for field ", key
				return false
			continue
		if pattern notin js:
			if ftype.required:
				echo "missing ", pattern, " from js"
				return false
			continue
		echo pattern, " ok"

	return true

proc parseField(ftype: FieldTypeDef; js: JsonNode): bool =
	result = true
	case ftype.kind:
	of Anything: discard
	of Primitive:
		result = js.kind in ftype.kinds
	of Complex:
		result = ftype.schema.parseSchema(js)
	of Either:
		result = ftype.a.parseField(js) or ftype.b.parseField(js)
	of List:
		for j in js.elems:
			result = ftype.member.parseField(j)
			if not result:
				break

if isMainModule:
	let
		content = stdin.newFileStream().readAll()
		js = content.parseJson()
	if js.kind != JObject:
		echo "dude, i was expecting a json object"
		quit(1)

	if "swagger" in js:
		if js["swagger"].getStr != "2.0":
			quit(0)
	else:
		quit(0)
	if not OpenApi2.parseSchema(js):
		quit(1)
