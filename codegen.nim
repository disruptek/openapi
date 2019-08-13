#? replace(sub = "\t", by = " ")

# TODO:
# transport; bind string->handler, eg. http, ws, etc.
# converters for json, xml and types
# compose calls
# parse replies
# auth schemes
# embed on-board dox
# link to external dox

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
	ConsumeResult* = object of RootObj
		ok*: bool
		schema*: Schema
		input*: JsonNode
		output*: NimNode

	PathItem* = object of ConsumeResult
		path*: string
		parsed*: ParserResult
		basePath*: string
		host*: string
		operations*: Table[string, Operation]
		parameters*: seq[Parameter]

	ParameterIn = enum
		InQuery = "query"
		InBody = "body"
		InHeader = "header"
		InPath = "path"
		InData = "formData"

	Parameter* = object of ConsumeResult
		name*: string
		description*: string
		required*: bool
		location*: ParameterIn

	Operation* = object of ConsumeResult
		op*: HttpOpName
		id*: string
		parameters*: seq[Parameter]

proc makeTypeDef*(ftype: FieldTypeDef; name: string; node: JsonNode = nil): NimNode
proc parseTypeDef(input: JsonNode): FieldTypeDef
proc parseTypeDefOrRef(input: JsonNode): NimNode

proc newExportedIdentNode(name: string): NimNode =
	## newIdentNode with an export annotation
	result = newNimNode(nnkPostfix)
	result.add newIdentNode("*")
	result.add newIdentNode(name)

proc isValidIdentifier(name: string): bool =
	## verify that the identifier has a reasonable name
	result = true
	if name in ["string", "int", "float", "bool", "object", "array", "from", "type", "template"]:
		result = false
	elif name.startsWith("_"):
		result = false
	elif "__" in name:
		result = false
	when declaredInScope(name):
		result = false

proc toValidIdentifier(name: string; star=true): NimNode =
	## permute identifiers until they are valid
	if name.isValidIdentifier:
		if star:
			result = newExportedIdentNode(name)
		else:
			result = newIdentNode(name)
	else:
		result = toValidIdentifier("oa" & name.replace("__", "_"), star=star)
		warning name & " is a bad choice of type name", result

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

when false:
	proc conjugateFieldType(name: string; format=""): FieldTypeDef =
		let major = name.guessJsonNodeKind()
		result = major.conjugateFieldType(format=format)

converter toNimNode(ftype: FieldTypeDef): NimNode =
	## render a fieldtypedef as nimnode
	if ftype == nil:
		return newCommentStmtNode("fieldtypedef was nil")
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
				newCommentStmtNode("you can't create a Primitive from " & $kind)
	of List:
		assert ftype.member != nil
		let elements = ftype.member.toNimNode
		#result = newCommentStmtNode("creating a List of " & $ftype.member.kind)
		#result.strVal.warning result
		result = quote do:
			seq[`elements`]
	of Complex:
		result = newCommentStmtNode("creating a " & $ftype.kind)
		result.strVal.warning result
	else:
		result = newCommentStmtNode("you can't create a typedef for a " & $ftype.kind)
		result.strVal.error result

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
	result = toValidIdentifier(target.split("/")[^1], star=false)

proc pluckRefTarget(input: JsonNode): NimNode =
	## sniff the type name and cast it to a nim identifier
	let target = input.pluckString("$ref")
	if target.isNone:
		return
	result = target.get().parseRefTarget()

proc elementTypeDef(input: JsonNode; name="nil"): NimNode {.deprecated.} =
	result = input.parseTypeDefOrRef()
	if result != nil:
		return
	let element = input.parseTypeDef()
	result = element.makeTypeDef(name, input)

iterator objectProperties(input: JsonNode): NimNode =
	## yield typedef nodes of a json object, and
	## ignore "$ref" nodes in the input
	var onedef, typedef: NimNode
	if input != nil:
		assert input.kind == JObject, "nonsensical json type in objectProperties"
		for k, v in input.pairs:
			if k == "$ref":
				continue
			# a single property typedef
			onedef = newNimNode(nnkIdentDefs)
			onedef.add k.toValidIdentifier()
			typedef = v.parseTypeDefOrRef()
			assert typedef != nil, "unable to parse type: " & $v
			onedef.add typedef
			onedef.add newEmptyNode()
			yield onedef

proc contains[T](t: tuple; v: T): bool =
	result = false
	for n in t.fields:
		if v == n:
			return true

proc defineMap(input: JsonNode): NimNode =
	## reference an existing map type or create a new one right here
	var
		target: NimNode
	assert input != nil
	assert input.kind == JObject

	let contents = (typed: "type" in input, refd: "$ref" in input)
	if false notin contents:
		# we'll let the $ref override...
		target = input.pluckRefTarget()
	elif true notin contents:
		# no type and no ref; use string
		target = newIdentNode("string")
	elif contents.refd:
		target = input.pluckRefTarget()
	else:
		assert contents.typed == true
		let ftype = input.parseTypeDef()
		if ftype.kind == Primitive:
			target = ftype.toNimNode
		else:
			# it's a List, Complex, or worse
			target = newIdentNode("string")

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
	# we would have exited sooner, but i wanted to make sure we could provide
	# a decent warning message above...
	if target != nil:
		result = target
	else:
		result.add reclist

proc defineObjectOrMap(input: JsonNode): NimNode =
	## reference an existing obj type or create a new one right here
	assert input != nil, "i should be getting non-nil input, i think"
	assert input.kind == JObject, "bizarre input: " & $input

	if "properties" in input and "additionalProperties" in input:
		error "both `properties` and `additionalProperties`" &
			" are defined:\n" & input.pretty

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
		result = input.defineMap()
	elif "items" in input:
		assert input["items"].kind == JObject
		result = input["items"].parseTypeDefOrRef()
		assert result != nil
		return quote do:
			seq[`result`]
	elif "allOf" in input:
		warning "allOf support is terrible!"
		assert input["allOf"].kind == JArray
		for n in input["allOf"]:
			result = n.defineObjectOrMap()
			if result != nil:
				break
	else:
		error "missing properties or additionalProperties in object:\n" &
			input.pretty

proc parseTypeDef(input: JsonNode): FieldTypeDef =
	## convert a typedef from json; eg. we may expect to look
	## for a type="something" and/or format="something-else"
	case input.kind:
	of JObject:
		if "type" in input:
			let
				major = input["type"].getStr
				#minor = input.getOrDefault("format").getStr
				kind = major.guessJsonNodeKind()
			result = kind.toFieldTypeDef()
		else:
			result = input.kind.toFieldTypeDef()
	of JArray:
		result = input.kind.toFieldTypeDef()
		if "items" in input:
			result.member = input["items"].parseTypeDef()
	else:
		result = input.kind.toFieldTypeDef()

proc parseTypeDefOrRef(input: JsonNode): NimNode =
	## convert a typedef from json to nimnode; this one will
	## provide the RHS of a typedef and performs a substitution
	## of an available $ref if available
	var ftype: FieldTypeDef
	if input == nil:
		return
	result = input.pluckRefTarget()
	if result != nil:
		return
	ftype = input.parseTypeDef()
	case ftype.kind:
	of List:
		assert input.kind == JObject
		if ftype.member == nil:
			if "items" in input:
				let target = input["items"].pluckRefTarget()
				if target != nil:
					return quote do:
						seq[`target`]
				else:
					ftype.member = input["items"].parseTypeDef()
					assert ftype.member != nil, "bad items: " & $input["items"]
	of Complex:
		if "type" notin input:
			warning "lacks `type` property:\n" & input.pretty
		if input.len == 0:
			# this is basically a "type" like {}
			return input.defineObjectOrMap()
		if "properties" in input:
			discard
		elif "additionalProperties" in input:
			discard
		elif "allOf" in input:
			warning "allOf poorly implemented!"
			assert input["allOf"].kind == JArray
			for n in input["allOf"]:
				return n.parseTypeDefOrRef()
		elif "type" in input:
			return input.parseTypeDef()
		else:
			result = newCommentStmtNode("lacks `type` property")
			result.strVal.warning result
			return
		return input.defineObjectOrMap()
	else:
		discard
	result = ftype.toNimNode

proc makeTypeDef*(ftype: FieldTypeDef; name: string; node: JsonNode = nil): NimNode =
	## toplevel type builder which emits symbols and associated types,
	## of Primitive, List, Complex forms
	let typeName = name.toValidIdentifier
	var
		input = node
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
			result = newCommentStmtNode(name &
				" lacks `items` property:\n" & input.pretty)
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
			result = newCommentStmtNode(name & "bizarre input:\n" & input.pretty)
			result.strVal.error
			return
		if input.len == 0:
			# this is basically a "type" like {}
			result = newNimNode(nnkTypeDef)
			result.add typeName
			result.add newEmptyNode()
			result.add input.defineObjectOrMap()
			return
		var major: string
		# see if it's an untyped value
		if "type" in input:
			major = input["type"].getStr
		else:
			if "properties" in input:
				warning name & " lacks `type` property"
				major = "object"
			elif "additionalProperties" in input:
				warning name & " lacks `type` property"
				major = "object"
			elif "allOf" in input:
				warning name & " lacks `type` property; allOf poorly implemented!"
				major = "object"
				assert input["allOf"].kind == JArray
				for n in input["allOf"]:
					input = n
					break
			else:
				result = newCommentStmtNode(name & " lacks `type` property")
				result.strVal.warning result
				return
		let
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

proc newPathItem(pr: ParserResult; path: string; input: JsonNode; root: JsonNode): PathItem =
	## create a PathItem result for a parsed node
	var
		op: Operation
	result = PathItem(ok: pr.ok, parsed: pr, path: path)
	if root != nil and root.kind == JObject and "basePath" in root:
		if root["basePath"].kind == JString:
			result.basePath = root["basePath"].getStr
	if root != nil and root.kind == JObject and "host" in root:
		if root["host"].kind == JString:
			result.host = root["host"].getStr
	if input == nil or input.kind != JObject:
		error "unimplemented path item input:\n" & input.pretty
		return
	if "$ref" in input:
		error "path item $ref is unimplemented:\n" & input.pretty
		return
	for opName in HttpOpName:
		if $opName notin input:
			continue
		#warning "operation " & $opName & "-->" & $input[$opName]

iterator paths(root: FieldTypeDef; input: JsonNode): PathItem =
	var
		schema: Schema
		pschema: Schema = nil
		parsed: ParserResult

	assert root.kind == Complex, "malformed schema: " & $root.schema

	while "paths" in root.schema:
		# make sure our schema is sane
		if root.schema["paths"].kind == Complex:
			pschema = root.schema["paths"].schema
		else:
			error "malformed paths schema: " & $root.schema["paths"]
			break

		# make sure our input is sane
		if input == nil or input.kind != JObject:
			warning "missing or invalid json input: " & $input
			break
		if "paths" notin input or input["paths"].kind != JObject:
			warning "missing or invalid paths in input: " & $input["paths"]
			break

		# find a good schema definition for ie. /{name}
		for k, v in pschema.pairs:
			if not k.startsWith("/"):
				continue
			schema = v.schema
			break

		# iterate over input and yield PathItems per each node
		for k, v in input["paths"].pairs:
			# spec says valid paths should start with /
			if not k.startsWith("/"):
				if not k.toLower.startsWith("x-"):
					warning "unrecognized path: " & k
				continue
			parsed = v.parsePair(k, schema)
			yield parsed.newPathItem(k, v, input)
		break

proc `$`(path: PathItem): string =
	if path.host != "":
		result = path.host
	if path.basePath != "/":
		result.add path.basePath
	result.add path.path

proc consume(content: string): ConsumeResult {.compileTime.} =
	var
		parsed: ParserResult
		schema: FieldTypeDef
		typedefs: seq[FieldTypeDef]

	result = ConsumeResult(ok: false)

	while true:
		try:
			result.input = content.parseJson()
			if result.input.kind != JObject:
				error "i was expecting a json object, but i got " &
					$result.input.kind
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
			typedefs = toSeq(definitions.schema.values)
			assert typedefs.len == 1, "dunno what to do with " &
				$typedefs.len & " definitions schemas"
			schema = typedefs[0]
			var
				typeSection = newNimNode(nnkTypeSection)
			for k, v in result.input["definitions"]:
				parsed = v.parsePair(k, schema)
				if not parsed.ok:
					error "parse error on definition for " & k
					break
				typeSection.add schema.makeTypeDef(k, node=v)
			result.output.add typeSection

		#for path in result.schema.paths(result.input):
		#	hint "path: " & $path

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
