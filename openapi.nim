#? replace(sub = "\t", by = " ")
import json
import streams

import parser
from schema2 import OpenApi2


if isMainModule:
	var input: JsonNode
	let
		content = stdin.newFileStream().readAll()
	while true:
		try:
			input = content.parseJson()
			if input.kind != JObject:
				echo "i was expecting a json object"
				break
		except JsonParsingError as e:
			echo "error parsing the input as json: ", e.msg
			break

		if "swagger" in input:
			if input["swagger"].getStr != "2.0":
				echo "we only know how to parse openapi-2.0 atm"
				break
		else:
			echo "no swagger version found in the input"
			break

		let pr = OpenApi2.parseSchema(input)
		if pr.ok:
			quit(0)
		echo $pr
		break
	quit(1)
