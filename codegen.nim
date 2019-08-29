#? replace(sub = "\t", by = " ")
import macros
import tables
import json
import strutils
import options

import spec
import parser
import paths
import typewrap

from schema2 import OpenApi2

type
	ConsumeResult* = object of RootObj
		ok*: bool
		schema*: Schema
		js*: JsonNode
		ast*: NimNode

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

	Parameter = object of ConsumeResult
		name*: string
		description*: string
		required*: bool
		location*: ParameterIn
		default*: JsonNode
		source*: JsonNode

	Response = object of ConsumeResult
		status: string
		description: string

	Operation = object of ConsumeResult
		meth*: HttpOpName
		path*: string
		operationId*: string
		parameters*: seq[Parameter]
		responses*: seq[Response]

	TypeDefResult* = object of ConsumeResult
		name: string
		comment: string
		ftype: FieldTypeDef
		wrapped: WrappedItem

	GuessTypeResult = tuple
		ok: bool
		major: JsonNodeKind
		minor: string

	WrappedField = WrappedType[FieldTypeDef, WrappedItem]
	WrappedItem = ref object
		name: string  ## this is necessarily the WrappedType.name
		case kind: FieldType
		of Primitive:
			primitive: JsonNode
		of List:
			list: WrappedField
		of Either:
			either: WrappedField
		of Anything:
			anything: WrappedField
		of Complex:
			complex: WrappedField

proc validNimIdentifier(s: string): bool =
	if s.len > 0 and s[0] in IdentStartChars:
		if s.len > 1 and '_' in [s[0], s[^1]]:
			return false
		for i in 1..s.len-1:
			if s[i] notin IdentChars:
				return false
			if s[i] == '_' and s[i-1] == '_':
				return false
		return true

proc newWrappedPrimitive(ftype: FieldTypeDef, name: string; js: JsonNode): WrappedItem =
	## a wrapped item that points to a primitive
	result = WrappedItem(kind: Primitive, name: name, primitive: js)
	assert ftype.kind == result.kind

proc newWrappedList(ftype: FieldTypeDef; name: string; js: JsonNode): WrappedItem =
	## a wrapped item that holds a list of other wrapped items
	#let wrapped = newLimb(ftype, name, @[])
	#result = WrappedItem(kind: List, name: name, list: wrapped)
	assert ftype.kind == result.kind

proc newWrappedComplex(ftype: FieldTypeDef; name: string; js: JsonNode = nil): WrappedItem =
	## a wrapped item that may contain named wrapped items
	let wrapped = newBranch[FieldTypeDef, WrappedItem](ftype, name)
	result = WrappedItem(kind: Complex, name: name, complex: wrapped)
	assert ftype.kind == result.kind

proc makeTypeDef*(ftype: FieldTypeDef; name: string; input: JsonNode = nil): TypeDefResult
proc parseTypeDef(input: JsonNode): FieldTypeDef
proc parseTypeDefOrRef(input: JsonNode): NimNode

proc newExportedIdentNode(name: string): NimNode =
	## newIdentNode with an export annotation
	assert name.validNimIdentifier == true
	result = newNimNode(nnkPostfix)
	result.add newIdentNode("*")
	result.add newIdentNode(name)

proc isValidIdentifier(name: string): bool =
	## verify that the identifier has a reasonable name
	if name.startsWith("_") and name != "_":
		result = false
	elif "__" in name:
		result = false
	else:
		result = name.validNimIdentifier

proc toValidIdentifier(name: string; star=true): NimNode =
	## permute identifiers until they are valid
	if name.isValidIdentifier:
		if star:
			result = newExportedIdentNode(name)
		else:
			result = newIdentNode(name)
	else:
		result = toValidIdentifier("oa" & name.replace("__", "_"), star=star)

proc guessJsonNodeKind(name: string): JsonNodeKind =
	## map openapi type names to their json node types
	result = case name:
	of "integer": JInt
	of "number": JFloat
	of "string": JString
	of "file": JString
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

proc parseRefTarget(target: string): NimNode {.deprecated.} =
	## turn a $ref -> string into a nim ident node
	let templ = "#/definitions/{name}".parseTemplate()
	assert templ.ok, "you couldn't parse your own template, doofus"
	let caught = templ.match(target)
	assert caught, "our template didn't match the ref: " & target
	result = toValidIdentifier(target.split("/")[^1], star=false)

proc pluckRefJson(root: JsonNode; input: JsonNode): JsonNode =
	## find and return the content of a json ref, if possible
	let target = input.pluckString("$ref")
	if target.isNone:
		return
	if root == nil:
		warning "unable to retrieve $ref in this context"
		return
	var paths = target.get().split("/")
	while paths.len > 0 and paths[0] in ["", "#"]:
		paths = paths[1..^1]
	result = root
	for p in paths:
		result = result[p]

proc pluckRefNode(input: JsonNode): NimNode =
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
	result = element.makeTypeDef(name, input).ast

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
		target = input.pluckRefNode()
	elif true notin contents:
		# no type and no ref; use string
		target = newIdentNode("string")
	elif contents.refd:
		target = input.pluckRefNode()
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
	let target = input.pluckRefNode()

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
	result = input.pluckRefNode()
	if result != nil:
		return

	if input.len == 0:
		# FIXME: not sure we want to swallow objects like {}
		result = input.defineMap()
	elif "properties" in input:
		result = input["properties"].defineObject()
	elif "additionalProperties" in input:
		result = input["additionalProperties"].defineMap()
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
	result = input.kind.toFieldTypeDef()
	case input.kind:
	of JObject:
		if "type" in input:
			let
				major = input["type"].getStr
				#minor = input.getOrDefault("format").getStr
				kind = major.guessJsonNodeKind()
			result = kind.toFieldTypeDef()
	of JArray:
		if "items" in input:
			result.member = input["items"].parseTypeDef()
	else:
		discard

proc parseTypeDefOrRef(input: JsonNode): NimNode =
	## convert a typedef from json to nimnode; this one will
	## provide the RHS of a typedef and performs a substitution
	## of an available $ref if available
	var ftype: FieldTypeDef
	if input == nil:
		return
	result = input.pluckRefNode()
	if result != nil:
		return
	ftype = input.parseTypeDef()
	case ftype.kind:
	of List:
		assert input.kind == JObject
		if ftype.member == nil:
			if "items" in input:
				let target = input["items"].pluckRefNode()
				if target != nil:
					return quote do:
						seq[`target`]
				else:
					ftype.member = input["items"].parseTypeDef()
					assert ftype.member != nil, "bad items: " & $input["items"]
		return ftype.toNimNode
	of Complex:
		#if "type" notin input:
		#	warning "lacks `type` property:\n" & input.pretty
		if "type" in input:
			return input.parseTypeDef()
		elif "allOf" in input:
			warning "allOf poorly implemented!"
			assert input["allOf"].kind == JArray
			for n in input["allOf"]:
				return n.parseTypeDefOrRef()
		elif input.len == 0:
			# it's okay, it's an empty map {}
			discard
		elif "properties" in input:
			# it's okay, it's an underspecified object
			discard
		elif "additionalProperties" in input:
			# it's okay, it's an underspecified map
			discard
		else:
			# i guess we can't really tell what it is...
			warning "lacks `type` property:\n" & input.pretty
			result = newCommentStmtNode("assuming it's an optional string...!")
			result.strVal.warning result
			return JString.optional
		return input.defineObjectOrMap()
	else:
		# it's a primitive or otherwise easily converted
		return ftype.toNimNode

proc fail(rh: var TypeDefResult; why: string; silent=false) =
	rh.ok = false
	rh.comment = rh.name & ": " & why
	if not silent:
		rh.ast = newCommentStmtNode(rh.comment)
		rh.ast.add newCommentStmtNode($rh.js)
	warning rh.comment, rh.ast
	warning rh.js.pretty, rh.ast

proc whine(rh: var TypeDefResult; why: string) {.deprecated.} =
	## issue warnings but don't necessarily
	## reset the success bool as a result
	let was = rh.ok
	rh.fail why, silent=true
	rh.ok = was or rh.ok

proc bomb(rh: var TypeDefResult; why: string) =
	rh.fail(why)
	error "unrecoverable error", rh.ast

proc whine(input: JsonNode; why: string) =
	warning why & ":\n" & input.pretty

proc guessType(js: JsonNode; root: JsonNode): GuessTypeResult =
	var
		major: string
		input = root.pluckRefJson(js)
	if input == nil:
		input = js
	
	case input.kind:
	of JObject:
		# see if it's an untyped value
		if input.len == 0:
			# this is a map like {}
			major = "object"
		elif "type" in input:
			major = input["type"].getStr
		elif "schema" in input:
			return input["schema"].guessType(root)
		else:
			# whine about any issues
			if "properties" in input:
				input.whine "objects should have a type=object property"
				major = "object"
			elif "additionalProperties" in input:
				input.whine "maps should have a type=object property"
				major = "object"
			elif "allOf" in input:
				input.whine "allOf is poorly implemented"
				major = "object"
				assert input["allOf"].kind == JArray
				for n in input["allOf"]:
					input = n
					break
			else:
				# we'll return if we cannot recognize the type
				warning "no type discovered:\n" & input.pretty
				return (ok: false, major: JNull, minor: "")
		let
			format = input.getOrDefault("format").getStr
			kind = major.guessJsonNodeKind()
		result = (ok: true, major: kind, minor: format)
	else:
		result = (ok: true, major: input.kind, minor: "")

proc rightHandType(ftype: FieldTypeDef; js: JsonNode; name="?"): TypeDefResult =
	result = TypeDefResult(ok: false, ftype: ftype, js: js, name: name)
	var input = js
	if ftype == nil:
		result.bomb "no schema provided for unpack"
		return

	if input == nil:
		result.bomb "no input for type unpack"
		return

	if ftype.kind in {List, Complex}:
		if input.kind != JObject:
			result.bomb "bad input for " & $input.kind
			return
		elif input.len == 0:
			# this is basically a "type" like {}
			result.ast = input.defineObjectOrMap()
			result.ok = true
			# skip that huge case
			return

	case ftype.kind:
	of Primitive:
		result.ast = ftype.toNimNode
	of List:
		# FIXME: clean this up
		if "items" notin input:
			result.bomb "lacks `items` property"
			return
		let member = input["items"].elementTypeDef()
		# because it's, like, what, 12 `Sym "[]"` records?
		result.ast = quote do:
			seq[`member`]
	of Complex:
		let k = input.guessType(root=nil) # no root here!
		if not k.ok:
			result.fail "unable to guess type of schema"
			return
		# do we need to define an object type here?
		if k.major == JObject:
			# name this object type and add the definition
			result.ast = input.defineObjectOrMap()

		# TODO: maybe we have some array code?
		#elif kind == JArray:

		else:
			# it's not an object; just figure out what it is and def it
			# create a new fieldtype, perhaps permuted by the format
			result.ftype = k.major.conjugateFieldType(format=k.minor)
			let
				# pass the same input through, for comment reasons
				rh = result.ftype.rightHandType(input, name=name)
			result.ast = rh.ast
			if not rh.ok:
				return
	else:
		result.fail "bad typedef kind " & $ftype.kind
		return

	# do anything else you need to do on a valid type held in result,
	# ie. if we get this far, we aren't merely commenting on bad data
	result.ok = true

proc makeTypeDef*(ftype: FieldTypeDef; name: string; input: JsonNode = nil): TypeDefResult =
	## toplevel type builder which emits symbols and associated types,
	## of Primitive, List, Complex forms

	result = TypeDefResult(ok: false, ftype: ftype, js: input, name: name)

	# no input, no problem
	if input == nil:
		result.bomb name & " lacks any type info"
		return

	var
		right: NimNode
		target = input.pluckRefNode()
		documentation = input.pluckDescription()

	if input.kind == JObject and input.len == 0:
		documentation = newCommentStmtNode(name & " lacks any type info")
		#documentation.strVal.warning
	if documentation == nil:
		documentation = newCommentStmtNode(name & " lacks `description`")

	# if there's a ref target (a symbol), then we'll just use that
	if target != nil:
		right = target

	# else unpack the type on the right-hand side
	else:
		let rh = rightHandType(ftype, input, name=name)
		assert rh.ast != nil
		# good or bad, we always get ast
		right = rh.ast
		if not rh.ok:
			return

	# sadly, still need to figure out how to do docs
	#result = documentation
	result.ast = newNimNode(nnkTypeDef)
	result.ast.add name.toValidIdentifier
	result.ast.add newEmptyNode()
	result.ast.add right
	result.ok = true

proc jsonKind(param: Parameter; root: JsonNode): JsonNodeKind =
	let kind = param.source.guessType(root)
	if kind.ok:
		return kind.major
	raise newException(ValueError, "unable to guess type:\n" & param.js.pretty)

proc newParameter(root: JsonNode; input: JsonNode): Parameter =
	assert input != nil and input.kind == JObject, "bizarre input: " &
		input.pretty
	var js = root.pluckRefJson(input)
	if js == nil:
		js = input
	result = Parameter(ok: false, js: js)
	result.name = js["name"].getStr
	result.location = parseEnum[ParameterIn](js["in"].getStr)
	result.required = js.getOrDefault("required").getBool
	result.description = js.getOrDefault("description").getStr
	result.default = js.getOrDefault("default")

	# `source` is a pointer to the JsonNode that defines the
	# format for the parameter; it can be overridden with `schema`
	while "schema" in js:
		js = js["schema"]
		var source = root.pluckRefJson(js)
		if source == nil:
			break
		js = source
	if result.source == nil:
		result.source = js

	result.ok = true

proc newResponse(root: JsonNode; status: string; input: JsonNode): Response =
	var js = root.pluckRefJson(input)
	if js == nil:
		js = input
	result = Response(ok: false, status: status, js: js)
	result.description = js.getOrDefault("description").getStr
	# TODO: save the schema
	result.ok = true

proc sanitizeIdentifier(name: string; capsOkay=false): string =
	## convert any string to a valid nim identifier in camelCase
	if name.validNimIdentifier:
		return name
	if name.len == 0:
		raise newException(ValueError, "empty identifier")
	for c in name:
		if c == '_' and result.len == 0:
			continue
		if c in IdentChars:
			result.add c
		elif result.len != 0 and result[^1] != '_':
			result.add '_'
	if not capsOkay and result[0].isUpperAscii:
		result[0] = result[0].toLowerAscii
	if result.len > 1:
		result.removeSuffix {'_'}
		result.removePrefix {'_'}
	if result[0] notin IdentStartChars:
		raise newException(ValueError,
			"identifiers cannot start with `" & result[0] & "`")
	assert result.validNimIdentifier, "bad identifier: " & result

proc saneName(param: Parameter): string =
	try:
		return sanitizeIdentifier(param.name, capsOkay=true)
	except ValueError:
		raise newException(ValueError,
			"unable to compose valid identifier for parameter `" & param.name & "`")

proc saneName(op: Operation): string =
	var attempt: seq[string]
	if op.operationId != "":
		attempt.add op.operationId
		attempt.add $op.meth & "_" & op.operationId
	attempt.add $op.meth & "_" & op.path
	for name in attempt:
		try:
			return sanitizeIdentifier(name, capsOkay=false)
		except ValueError:
			discard
	raise newException(ValueError,
		"unable to compose valid identifier; attempted these: " & attempt.repr)

proc toJsonIdentDefs(param: Parameter): NimNode =
	let name = newIdentNode(param.saneName)
	if param.required:
		result = newIdentDefs(name, newIdentNode("JsonNode"))
	else:
		result = newIdentDefs(name, newIdentNode("JsonNode"), newNilLit())

proc toNewJsonNimNode(js: JsonNode): NimNode =
	case js.kind:
	of JInt:
		let i = js.getInt
		result = quote do: newJInt(`i`)
	of JString:
		let s = js.getStr
		result = quote do: newJString(`s`)
	of JFloat:
		let f = js.getFloat
		result = quote do: newJFloat(`f`)
	of JBool:
		let b = newIdentNode($js.getBool)
		result = quote do: newJBool(`b`)
	else:
		raise newException(ValueError, "unsupported input: " & $js.kind)

proc shortRepr(js: JsonNode): string =
	result = $js.kind & "(" & $js & ")"

proc newOperation(root: JsonNode; meth: HttpOpName; path: string; input: JsonNode): Operation =
	var
		response: Response
		parameter: Parameter
	var js = root.pluckRefJson(input)
	if js == nil:
		js = input
	result = Operation(ok: false, meth: meth, path: path, js: js)
	result.operationId = js.getOrDefault("operationId").getStr
	if result.operationId == "":
		var msg = "operationId not defined for " & toUpperAscii($meth)
		if path == "":
			msg = "empty path and " & msg
			error msg
			return
		else:
			msg = msg & " on `" & path & "`"
			warning msg
			let sane = result.saneName
			warning "invented operation name `" & sane & "`"
			result.operationId = sane
	if "responses" in js:
		for status, resp in js["responses"].pairs:
			response = root.newResponse(status, resp)
			if response.ok:
				result.responses.add response
			else:
				warning "bad response:\n" & resp.pretty
	if "parameters" in js:
		const WarnIdentityClash = true
		when WarnIdentityClash:
			var
				saneNames: seq[string] = @[]
				sane: string
		for param in js["parameters"]:
			parameter = root.newParameter(param)
			if not parameter.ok:
				error "bad parameter:\n" & param.pretty
				continue
			result.parameters.add parameter
			when WarnIdentityClash:
				sane = parameter.saneName
				for name in saneNames:
					if not sane.eqIdent(name):
						continue
					let msg = "parameter `" & name & "` and `" & parameter.name &
						"` yield the same Nim identifier"
					error msg
					return
				saneNames.add sane
	let
		opName = result.saneName
		opIdent = newExportedIdentNode(opName)
	
	var
		opJsAssertions = newStmtList()
		opBody = newStmtList()
		opJsParams: seq[NimNode] = @[newEmptyNode()]
	
	# add required params first, then optionals
	for param in result.parameters:
		if param.required:
			opJsParams.add param.toJsonIdentDefs
			var
				errmsg = "`" & param.saneName & "` is a required parameter"
				saneIdent = newIdentNode(param.saneName)
			opJsAssertions.add quote do:
				assert `saneIdent` != nil, `errmsg`

	for param in result.parameters:
		if not param.required:
			opJsParams.add param.toJsonIdentDefs

	opBody.add opJsAssertions
	let inputsIdent = newIdentNode("inputs")
	opBody.add quote do:
		var `inputsIdent` = newJObject()

	# assert proper parameter types and/or set defaults
	for param in result.parameters:
		var
			insane = param.name
			sane = param.saneName
			saneIdent = newIdentNode(param.saneName)
			jsKind = param.jsonKind(root)
			kindIdent = newIdentNode($jsKind)
			useDefault = false
			defNode: NimNode
			errmsg: string
		errmsg = "expected " & $jsKind & " for `" & sane & "` but received "
		if param.default != nil:
			if jsKind == param.default.kind:
				useDefault = true
			else:
				# provide a warning if the default type doesn't match the input
				warning "`" & sane & "` parameter in `" & $result.operationId &
					"` is " & $jsKind & " but the default is " &
					param.default.shortRepr & "; omitting code to supply the default"
		# TODO: clean this up into a manually-constructed ladder to merge asserts
		if useDefault:
			# set default value for input
			defNode = param.default.toNewJsonNimNode
			opBody.add quote do:
				if `saneIdent` == nil:
					inputs.add `insane`, `defNode`
				else:
					assert `saneIdent`.kind == `kindIdent`,
						`errmsg` & $(`saneIdent`.kind)
					inputs.add `insane`, `saneIdent`
		else:
			# no default is available; use the argument
			opBody.add quote do:
				if `saneIdent` != nil:
					assert `saneIdent`.kind == `kindIdent`,
						`errmsg` & $(`saneIdent`.kind)
					inputs.add `insane`, `saneIdent`

	result.ast = newStmtList()
	result.ast.add newProc(opIdent, opJsParams, opBody)
	result.ok = true

proc newPathItem(root: JsonNode; path: string; input: JsonNode): PathItem =
	## create a PathItem result for a parsed node
	var
		op: Operation
	result = PathItem(ok: false, path: path, js: input)
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
	# look for operation names in the input
	for opName in HttpOpName:
		if $opName notin input:
			continue
		op = root.newOperation(opName, path, input[$opName])
		if not op.ok:
			warning "unable to parse " & $opName & " on " & path
			continue
		result.operations[$opName] = op
	result.ok = true

iterator paths(root: JsonNode; ftype: FieldTypeDef): PathItem =
	var
		schema: Schema
		pschema: Schema = nil

	assert ftype.kind == Complex, "malformed schema: " & $ftype.schema

	while "paths" in ftype.schema:
		# make sure our schema is sane
		if ftype.schema["paths"].kind == Complex:
			pschema = ftype.schema["paths"].schema
		else:
			error "malformed paths schema: " & $ftype.schema["paths"]
			break

		# make sure our input is sane
		if root == nil or root.kind != JObject:
			warning "missing or invalid json input: " & $root
			break
		if "paths" notin root or root["paths"].kind != JObject:
			warning "missing or invalid paths in input: " & $root["paths"]
			break

		# find a good schema definition for ie. /{name}
		for k, v in pschema.pairs:
			if not k.startsWith("/"):
				continue
			schema = v.schema
			break

		# iterate over input and yield PathItems per each node
		for k, v in root["paths"].pairs:
			# spec says valid paths should start with /
			if not k.startsWith("/"):
				if not k.toLower.startsWith("x-"):
					warning "unrecognized path: " & k
				continue
			yield root.newPathItem(k, v)
		break

proc `$`*(path: PathItem): string =
	if path.host != "":
		result = path.host
	if path.basePath != "/":
		result.add path.basePath
	result.add path.path

proc `$`*(op: Operation): string =
	result = op.saneName

iterator wrapOneType(ftype: FieldTypeDef; name: string; input: JsonNode): WrappedItem {.deprecated.} =
	case ftype.kind:
	of Primitive:
		yield ftype.newWrappedPrimitive(name, input)
	of List:
		error "unable to parse lists"
		yield ftype.newWrappedList(name, input)
	of Complex:
		yield ftype.newWrappedComplex(name, input)
	else:
		warning "unable to wrap " & $ftype.kind

proc consume(content: string): ConsumeResult {.compileTime.} =
	when false:
		var
			parsed: ParserResult
			schema: FieldTypeDef
			typedefs: seq[FieldTypeDef]
			tree: WrappedField

	result = ConsumeResult(ok: false)

	while true:
		try:
			result.js = content.parseJson()
			if result.js.kind != JObject:
				error "i was expecting a json object, but i got " &
					$result.js.kind
				break
		except JsonParsingError as e:
			error "error parsing the input as json: " & e.msg
			break
		except ValueError:
			error "json parsing failed, probably due to an overlarge number"
			break

		if "swagger" in result.js:
			if result.js["swagger"].getStr != "2.0":
				error "we only know how to parse openapi-2.0 atm"
				break
			result.schema = OpenApi2
		else:
			error "no swagger version found in the input"
			break

		let pr = result.schema.parseSchema(result.js)
		if not pr.ok:
			break

		# add some imports we'll want
		# FIXME: make sure we need tables before importing it
		let imports = quote do:
			import json
		let preface = newCommentStmtNode "auto-generated via openapi macro"
		result.ast = newStmtList [preface, imports]

		# deprecated
		when false:
			tree = newBranch[FieldTypeDef, WrappedItem](anything({}), "tree")
			tree["definitions"] = newBranch[FieldTypeDef, WrappedItem](anything({}), "definitions")
			tree["parameters"] = newBranch[FieldTypeDef, WrappedItem](anything({}), "parameters")
			if "definitions" in result.js:
				let
					definitions = result.schema["definitions"]
				typedefs = toSeq(definitions.schema.values)
				assert typedefs.len == 1, "dunno what to do with " &
					$typedefs.len & " definitions schemas"
				schema = typedefs[0]
				var
					typeSection = newNimNode(nnkTypeSection)
					deftree = tree["definitions"]
				for k, v in result.js["definitions"]:
					parsed = v.parsePair(k, schema)
					if not parsed.ok:
						error "parse error on definition for " & k
						break
					for wrapped in parsed.ftype.wrapOneType(k, v):
						if wrapped.name in deftree:
							warning "not redefining " & wrapped.name
							continue
						case wrapped.kind:
						of Primitive:
							deftree[k] = newLeaf(parsed.ftype, k, wrapped)
						of Complex:
							deftree[k] = newBranch[FieldTypeDef, WrappedItem](parsed.ftype, k)
						else:
							error "can't grok " & k & " of type " & $wrapped.kind
					var onedef = schema.makeTypeDef(k, input=v)
					if onedef.ok:
						typeSection.add onedef.ast
					else:
						warning "unable to make typedef for " & k
					result.ast.add typeSection

		for path in result.js.paths(result.schema):
			for meth, op in path.operations.pairs:
				result.ast.add op.ast

		result.ok = true
		break

macro openapi*(inputfn: static[string]; outputfn: static[string]=""; body: typed): untyped =
	let content = staticRead(`inputfn`)
	var consumed = content.consume()
	if consumed.ok == false:
		error "openapi: unable to parse " & `inputfn`
		return
	result = consumed.ast

	if `outputfn` == "":
		hint "openapi: (provide a filename to save API source)"
	else:
		hint "openapi: writing output to " & `outputfn`
		writeFile(`outputfn`, result.repr)
		result = quote do:
			import `outputfn`
			`body`
