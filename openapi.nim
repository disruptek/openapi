#? replace(sub = "\t", by = " ")
import os
import json
import times
import re

import spec

from schema2 import OpenApi2

proc parseField(typed: FieldTypeDef; js: JsonNode): bool

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
		var typed = schema[key]
		if typed.parseField(value):
			echo key, " ok"
			continue
		echo "parse failure for field ", key
		return false
	for pattern, typed in schema.pairs:
		if typed.pattern:
			var rex = re(pattern, {reIgnoreCase})
			for key in missing:
				if not key.match(rex):
					continue
				if typed.parseField(js[key]):
					break
				echo "parse failure for field ", key
				return false
			continue
		if pattern notin js:
			if typed.required:
				echo "missing ", pattern, " from js"
				return false
			continue
		echo pattern, " ok"

	return true

proc parseField(typed: FieldTypeDef; js: JsonNode): bool =
	result = true
	case typed.kind:
	of Anything: discard
	of Natural:
		result = js.kind in typed.kinds
	of Complex:
		result = typed.schema.parseSchema(js)
	of Either:
		result = typed.a.parseField(js) or typed.b.parseField(js)
	of List:
		for j in js.elems:
			result = typed.member.parseField(j)
			if not result:
				break

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
