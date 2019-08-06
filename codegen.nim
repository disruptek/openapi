#? replace(sub = "\t", by = " ")
import macros
import tables
import json
import sequtils
import strutils
import options

import spec
import parser
import paths

from schema2 import OpenApi2

type
	ConsumeResult = object
		ok: bool
		schema: Schema
		input: JsonNode
		output: NimNode

proc guessJsonNodeKind(name: string): JsonNodeKind =
	## map openapi type names to their json node types
	result = case name:
	of "integer": JInt
	of "number": JFloat
	of "string": JString
	of "boolean": JBool
	of "array": JArray
	of "object": JObject
	of "null": JNull
	else:
		raise newException(Defect, "unknown type: " & name)

proc isKnownFormat(major: JsonNodeKind; format=""): bool =
	## it is known (and appropriate to the major)
	case major:
	of JInt:
		result = case format:
		of "", "integer", "int32", "long", "int64": true
		else: false
	of JFloat:
		result = case format:
		of "", "number", "float", "double": true
		else: false
	of JString:
		result = case format:
		of "", "string", "password", "file": true
		of "byte", "binary": true
		of "date", "date-time": true
		else: false
	of JBool:
		result = case format:
		of "", "boolean": true
		else: false
	of JArray:
		result = case format:
		of "", "array": true
		else: false
	of JObject:
		result = case format:
		of "", "object": true
		else: false
	of JNull:
		result = case format:
		of "", "null": true
		else: false

proc conjugateFieldType(major: JsonNodeKind; format=""): FieldTypeDef =
	## makes a typedef given node kind and optional format;
	## (this should someday handle arbitrary formats)
	if not major.isKnownFormat(format):
		warning $major & " type has unknown format `" & format & "`"
	result = major.toFieldTypeDef

#[
proc conjugateFieldType(name: string; format=""): FieldTypeDef =
	let major = name.guessJsonNodeKind()
	result = major.conjugateFieldType(format=format)
]#

converter toNimNode(ftype: FieldTypeDef): NimNode =
	## render a fieldtypedef as nimnode
	if ftype == nil:
		return newCommentStmtNode("attempted to convert to nil")
	case ftype.kind:
	of Primitive:
		if ftype.kinds.card == 0:
			return newCommentStmtNode("missing type specification")
		if ftype.kinds.card != 1:
			return newCommentStmtNode("multiple types is too many")
		for kind in ftype.kinds:
			return case kind:
			of JInt: newIdentNode("int")
			of JFloat: newIdentNode("float")
			of JString: newIdentNode("string")
			of JBool: newIdentNode("bool")
			of JNull: newNimNode(nnkNilLit)
			else:
				newCommentStmtNode("you can't create a typedef for a " & $kind)
	of List:
		assert false, "unimplemented"
		let elements = ftype.member.toNimNode
		result = newCommentStmtNode("you can't create a typedef for a " & $ftype.kind)
		result.strVal.warning result
		result.add quote do:
			seq[`elements`]
	else:
		result = newCommentStmtNode("you can't create a typedef for a " & $ftype.kind)
		result.strVal.warning result

proc pluckString(input: JsonNode; key: string): Option[string] =
	## a robust getter for string values in json
	if input == nil:
		return
	if input.kind != JObject:
		return
	if key notin input:
		return
	result = some(input[key].getStr)

proc pluckDescription(input: JsonNode): NimNode =
	let desc = input.pluckString("description")
	if desc.isSome:
		return newCommentStmtNode(desc.get())
	return newCommentStmtNode("(no description available)")

proc parseRefTarget(target: string): NimNode =
	## turn a $ref -> string into a nim ident node
	let templ = "#/definitions/{name}".parseTemplate()
	assert templ.ok, "you couldn't parse your own template, doofus"
	let caught = templ.match(target)
	assert caught, "our template didn't match the ref: " & target
	result = newIdentNode(target.split("/")[^1])

proc pluckRefTarget(input: JsonNode): NimNode =
	## sniff the type name and cast it to a nim identifier
	let target = input.pluckString("$ref")
	if target.isNone:
		return
	result = target.get().parseRefTarget()

proc makeTypeDef*(ftype: FieldTypeDef; name: string; input: JsonNode = nil): NimNode

proc parseTypeDef(input: JsonNode): NimNode =
	## convert a typedef from json to nim
	result = input.pluckRefTarget()
	if input == nil:
		return
	if result == nil:
		result = input.kind.toFieldTypeDef.toNimNode

proc elementTypeDef(input: JsonNode; name="nil"): NimNode =
	result = input.pluckRefTarget()
	if result == nil:
		result = input.parseTypeDef()
		if result != nil:
			return
		assert false, "unimplemented"
		let element = input.kind.toFieldTypeDef
		result = element.makeTypeDef(name, input)

iterator objectProperties(input: JsonNode): NimNode =
	## yield typedef nodes of a json object, and
	## ignore "$ref" nodes in the input
	var onedef, typedef, target: NimNode
	if input != nil:
		assert input.kind == JObject, "nonsensical json type in objectProperties"
		for k, v in input.pairs:
			if k == "$ref":
				continue
			onedef = newNimNode(nnkIdentDefs)
			onedef.add newIdentNode(k)
			target = v.pluckRefTarget()
			if target == nil:
				typedef = v.parseTypeDef()
				assert typedef != nil, "unable to parse type: " & $v
				onedef.add typedef
			else:
				onedef.add target
			onedef.add newEmptyNode()
			yield onedef

proc isValidIdentifier(name: string): bool =
	## verify that the identifier has a reasonable name
	result = true
	if name in ["string", "int", "float", "bool", "object", "array"]:
		result = false
	when declaredInScope(name):
		result = false

proc toValidIdentifier(name: string): NimNode =
	## permute identifiers until they are valid
	if name.isValidIdentifier:
		result = newIdentNode(name)
	else:
		result = toValidIdentifier("oa" & name)
		warning name & " is a bad choice of type name", result

proc defineMap(input: JsonNode): NimNode =
	## reference an existing map type or create a new one right here
	var target = input.pluckRefTarget()
	if target == nil:
		target = input.parseTypeDef()
	assert target != nil, "unable to parse map value type: " & $input

	return quote do:
		Table[string, `target`]

proc defineObject(input: JsonNode): NimNode =
	## reference an existing obj type or create a new one right here
	assert input != nil, "i should be getting non-nil input, i think"
	var reclist: NimNode
	let target = input.pluckRefTarget()

	# the object is composed thusly
	result = newNimNode(nnkObjectTy)
	result.add newEmptyNode()
	result.add newEmptyNode()
	reclist = newNimNode(nnkRecList)
	for def in input.objectProperties:
		if target != nil:
			warning "found a properties ref and 1+ props: " & def.strVal, result
			break
		reclist.add def
	result.add reclist

proc defineObjectOrMap(input: JsonNode): NimNode =
	## reference an existing obj type or create a new one right here
	assert input != nil, "i should be getting non-nil input, i think"
	assert input.kind == JObject, "bizarre input: " & $input

	if "properties" in input and "additionalProperties" in input:
		error "both `properties` and `additionalProperties` are defined"

	# if we have a ref at this root, well, just use that
	result = input.pluckRefTarget()
	if result != nil:
		return

	if "properties" in input:
		result = input["properties"].defineObject()
	elif "additionalProperties" in input:
		result = input["additionalProperties"].defineMap()
	elif input.len == 0:
		# FIXME: not sure we want to swallow objects like {}
		result = input.defineObject()
	else:
		error "missing properties or additionalProperties in object"

proc makeTypeDef*(ftype: FieldTypeDef; name: string; input: JsonNode = nil): NimNode =
	## these are backed by SchemaObject
	let typeName = name.toValidIdentifier
	var
		target = input.pluckRefTarget()
		documentation = input.pluckDescription()

	if input != nil and input.kind == JObject and input.len == 0:
		documentation = newCommentStmtNode(name & " lacks any type info")
		documentation.strVal.warning
	if documentation == nil:
		documentation = newCommentStmtNode(name & " lacks `description`")

	# try to use a ref (pointer) to an equivalent type early, if possible
	if target != nil:
		result = newNimNode(nnkTypeDef)
		result.add typeName
		result.add newEmptyNode()
		result.add target
		return

	case ftype.kind:
	of Primitive:
		result = newNimNode(nnkTypeDef)
		result.add typeName
		result.add newEmptyNode()
		result.add ftype.toNimNode
	of List:
		# FIXME: clean this up
		if "items" notin input:
			result = newCommentStmtNode(name & " lacks `items` property")
			result.strVal.error
			return
		let member = input["items"].elementTypeDef()
		result = newNimNode(nnkTypeDef)
		result.add typeName
		result.add newEmptyNode()
		# because it's, like, what, 12 `Sym "[]"` records?
		result.add quote do:
			seq[`member`]
	of Complex:
		if input == nil or input.kind != JObject:
			result = newCommentStmtNode(name & "bizarre input: " & $input)
			result.strVal.error
			return
		if input.len == 0:
			# this is basically a "type" like {}
			result = newNimNode(nnkTypeDef)
			result.add typeName
			result.add newEmptyNode()
			result.add input.defineObjectOrMap()
			return
		# see if it's an untyped value
		if "type" notin input:
			result = newCommentStmtNode(name & " lacks `type` property")
			result.strVal.warning
			return
		let
			major = input["type"].getStr
			minor = input.getOrDefault("format").getStr
			kind = major.guessJsonNodeKind()
		# do we need to define an object type here?
		if kind in {JObject}:
			# name this object type and add the definition
			result = newNimNode(nnkTypeDef)
			result.add typeName
			result.add newEmptyNode()
			result.add input.defineObjectOrMap()
			return
		# it's not an object; just figure out what it is and def it
		let rhs = kind.conjugateFieldType(format=minor)
		# pass the same input through, for comment reasons
		result = rhs.makeTypeDef(name, input)
	else:
		result = newCommentStmtNode(name & " -- bad typedef kind " & $ftype.kind)
		result.strVal.warning
		return

proc consume(content: string): ConsumeResult {.compileTime.} =
	result = ConsumeResult(ok: false)

	while true:
		try:
			result.input = content.parseJson()
			if result.input.kind != JObject:
				error "i was expecting a json object, but i got " & $result.input.kind
				break
		except JsonParsingError as e:
			error "error parsing the input as json: " & e.msg
			break
		except ValueError:
			error "json parsing failed, probably due to an overlarge number"
			break

		if "swagger" in result.input:
			if result.input["swagger"].getStr != "2.0":
				error "we only know how to parse openapi-2.0 atm"
				break
			result.schema = OpenApi2
		else:
			error "no swagger version found in the input"
			break

		let pr = result.schema.parseSchema(result.input)
		if not pr.ok:
			break

		# add some imports we'll want
		# FIXME: make sure we need tables before importing it
		let imports = quote do:
			import tables
		let preface = newCommentStmtNode "auto-generated via openapi macro"
		result.output = newStmtList [preface, imports]

		# get some types defined
		if "definitions" in result.input:
			let
				definitions = result.schema["definitions"]
				schemas = toSeq(definitions.schema.values)
			assert schemas.len == 1, "dunno what to do with " & $schemas.len &
				" definitions schemas"
			let
				schema = schemas[0]
			var
				parsed: ParserResult
				typeSection = newNimNode(nnkTypeSection)
			for k, v in result.input["definitions"]:
				parsed = v.parsePair(k, schema)
				if not parsed.ok:
					error "parse error on definition for " & k
					break
				typeSection.add schema.makeTypeDef(k, input=v)
			result.output.add typeSection

		result.ok = true
		break
	when false:
		echo result.output.treeRepr

macro openapi*(inputfn: static[string]; outputfn: static[string]=""; body: typed): untyped =
	let content = staticRead(`inputfn`)
	var consumed = content.consume()
	if consumed.ok == false:
		error "openapi: unable to parse " & `inputfn`
		return
	result = consumed.output

	if `outputfn` == "":
		hint "openapi: (provide a filename to save API source)"
	else:
		hint "openapi: writing output to " & `outputfn`
		writeFile(`outputfn`, result.repr)
		result = quote do:
			import `outputfn`
			`body`
