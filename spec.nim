#? replace(sub = "\t", by = " ")
import json
import tables

when defined(debug):
	import strformat

export JsonNodeKind

type
	# we may use the semantics of ordered tables to ensure that
	# we only iterate over patterned field names after traversing
	# the un-patterned names, so change this type at your peril
	Schema* = OrderedTableRef[FieldName, FieldTypeDef]   ## complex objects

	FieldName* = string ## the field name doubles as the pattern
	FieldType* = enum   ## variant discriminator for value types
		Anything ## anything or nothing (nullable)
		Natural, ## a primitive value (integer, string, etc.)
		List,    ## an array
		Either,  ## one of 2+ possible values
		Complex  ## a map-like object
	FieldTypeDef* = ref object ## the type for any given value
		kinds: set[JsonNodeKind]
		pattern: bool
		required: bool
		case kind: FieldType
		of Anything, Natural: discard
		of Either:
			a: FieldTypeDef
			b: FieldTypeDef
		of List:
			member: FieldTypeDef
		of Complex:
			schema: Schema

proc `$`*(typed: FieldTypeDef): string =
	when defined(debug):
		result = &"{typed.kind} {typed.kinds} req={typed.required} pat={typed.pattern}"
		if typed.kind == Complex:
			result &= " len=" & $typed.schema.len
	else:
		result = "(debug builds are rad)"

proc `|`*(a: FieldTypeDef; b: FieldTypeDef): FieldTypeDef =
	## the field may be represented by either of two types
	result = FieldTypeDef(kind: Either,
		kinds: a.kinds + b.kinds,
		pattern: a.pattern or b.pattern,
		required: a.required or b.required,
		a: a, b: b)

proc newFieldTypeDef*(kind: FieldType; kinds: set[JsonNodeKind]={};
	pattern=false, required=false, member: FieldTypeDef=nil;
	schema: Schema=nil): FieldTypeDef =
	case kind:
	of Natural:
		assert kinds != {}
		assert JObject notin kinds, "JObject is an exclusive sub-type"
		assert JArray notin kinds, "JArray is an exclusive sub-type"
		result = FieldTypeDef(kind: Natural, kinds: kinds, pattern: pattern, required: required)
	of Complex:
		result = FieldTypeDef(kind: Complex, kinds: {JObject}, pattern: pattern, required: required,
			schema: schema)
	of Anything:
		result = FieldTypeDef(kind: Anything, kinds: {}, pattern: pattern, required: required)
	of List:
		result = FieldTypeDef(kind: List, kinds: {JArray}, pattern: pattern, required: required,
			member: member)
	of Either:
		result = FieldTypeDef(kind: Either, kinds: {}, pattern: pattern, required: required)
	#else:
	#	raise newException(Defect, "unimplemented " & $kind & " field")

proc newSchema*(fields: openArray[(FieldName, FieldTypeDef)]): Schema =
	result = newOrderedTable(fields)

converter toSchema*(fields: openArray[(FieldName, FieldTypeDef)]): Schema =
	result = newSchema(fields)

converter toFieldTypeDef*(k: JsonNodeKind): FieldTypeDef =
	case k:
	of JObject:
		result = Complex.newFieldTypeDef(kinds={k})
	of JArray:
		result = List.newFieldTypeDef(kinds={k})
	else:
		result = Natural.newFieldTypeDef(kinds={k})

converter toFieldTypeDef*(s: set[JsonNodeKind]): FieldTypeDef =
	if JObject in s:
		assert s == {JObject}, "JObject is an exclusive sub-type"
		result = Complex.newFieldTypeDef(kinds=s)
	elif JArray in s:
		assert s == {JArray}, "JArray is an exclusive sub-type"
		result = List.newFieldTypeDef(kinds=s)
	elif s == {}:
		result = Anything.newFieldTypeDef(kinds={})
	else:
		result = Natural.newFieldTypeDef(kinds=s)

proc arrayOf*(member: FieldTypeDef): FieldTypeDef =
	result = FieldTypeDef(kind: List, kinds: {JArray},
		pattern: member.pattern, required: member.required,
		member: member)

converter toFieldTypeDef*(c: Schema): FieldTypeDef =
	result = Complex.newFieldTypeDef(schema=c)

converter toFieldTypeDef*(list: openArray[FieldTypeDef]): FieldTypeDef =
	assert list.len == 1, "provide only one list member typedef"
	let member = list[0]
	result = List.newFieldTypeDef(pattern=member.pattern,
		required=member.required, member=member)

proc paint(src: FieldTypeDef; dst: FieldTypeDef) =
	## copy variant values for immutable conversion reasons
	assert src.kind == dst.kind, "unable to paint fields of differing type"
	case src.kind:
	of Complex:
		dst.schema = src.schema
	of List:
		dst.member = src.member
	of Either:
		dst.a = src.a
		dst.b = src.b
	of Anything, Natural: discard

proc required*(t: FieldTypeDef): FieldTypeDef =
	## the field is required and must be present in the input
	result = t.kind.newFieldTypeDef(kinds=t.kinds, pattern=t.pattern,
		required=true)
	t.paint(result)

proc optional*(t: FieldTypeDef): FieldTypeDef =
	## the field is optional and may|not appear in the input
	result = t.kind.newFieldTypeDef(kinds=t.kinds, pattern=t.pattern,
		required=false)
	t.paint(result)

proc patterned*(t: FieldTypeDef): FieldTypeDef =
	## the field name associated with this value is a regex
	result = t.kind.newFieldTypeDef(kinds=t.kinds, pattern=true,
		required=t.required)
	t.paint(result)

proc unpatterned*(t: FieldTypeDef): FieldTypeDef =
	## the field name associated with this value isn't a regex
	result = t.kind.newFieldTypeDef(kinds=t.kinds, pattern=false,
		required=t.required)
	t.paint(result)

proc anything*(): FieldTypeDef =
	## any type, even null; defaults to optional
	result = Anything.newFieldTypeDef(required=false)

proc anything*(s: set[JsonNodeKind]): FieldTypeDef =
	## any type, even null; defaults to optional
	assert s == {}
	result = Anything.newFieldTypeDef(required=false)
