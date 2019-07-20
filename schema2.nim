#? replace(sub = "\t", by = " ")
import spec

# this is rather critical for reasons
import tables

let Info = {
	"title": required JString,
	"version": required JString,

	"description": optional JString,
	"termsOfService": optional JString,
	"contact": optional {
		"name": optional JString,
		"url": optional JString,
		"email": optional JString,

		"^x-": patterned optional anything {},
	}.toSchema,
	"license": optional {
		"name": required JString,

		"url": optional JString,

		"^x-": patterned optional anything {},
	}.toSchema,

	"^x-": patterned optional anything {},
}.toSchema

let Reference = {
	"$ref": required JString,
}.toSchema

let ExternalDocs = {
	"url": required JString,

	"description": optional JString,

	"^x-": patterned anything {},
}.toSchema

let SecurityRequirement = {
	"{name}": patterned optional JString.arrayOf,
}.toSchema

let XmlObject = {
	"name": optional JString,
	"namespace": optional JString,
	"prefix": optional JString,
	"attribute": optional JBool,
	"wrapped": optional JBool,

	"^x-": optional patterned anything {},
}.toSchema

# enum values could be literally anything.
# not sure we can validate them beyond the guarantees json provides...
let EnumArray = arrayOf(anything {})

var Items = {
	"type": required JString,

	"format": optional JString,
	"collectionFormat": optional JString,
	"default": unpatterned optional anything {},
	"maximum": optional JInt,
	"exclusiveMaximum": optional JInt,
	"minimum": optional JInt,
	"exclusiveMinimum": optional JBool,
	"maxLength": optional JInt,
	"minLength": optional JInt,
	"pattern": optional JString,
	"maxItems": optional JInt,
	"minItems": optional JInt,
	"uniqueItems": optional JBool,
	"enum": optional EnumArray,
	"multipleOf": optional JInt,

	"^x-": optional patterned anything {},
}.toSchema

# recursive type in case the parent type is array, in which
# case this field reflects the type of array members
Items["items"] = Items

let SchemaObject = {
	"$ref": optional Reference,

	# per json:
	"type": required JString,
	# could be "array" or "file", too ?  openapi unclear on this.

	"format": optional JString,
	"title": optional JString,
	"description": optional JString,
	"default": optional anything {},  # it must match the "type" above
	"multipleOf": optional JInt,

	# per swagger:
	"discriminator": optional JString,
	"readOnly": optional JBool,
	"xml": optional XmlObject,
	"externalDocs": optional ExternalDocs,
	"example": optional unpatterned anything {},

	# from items
	"items": optional Items,
	"maximum": optional JInt,
	"exclusiveMaximum": optional JInt,
	"minimum": optional JInt,
	"exclusiveMinimum": optional JBool,
	"maxLength": optional JInt,
	"minLength": optional JInt,
	"pattern": optional JString,
	"maxItems": optional JInt,
	"minItems": optional JInt,
	"uniqueItems": optional JBool,

	# extra per json schema
	"maxProperties": optional JInt,
	"minProperties": optional JInt,
	"required": optional JBool,
	"enum": optional EnumArray,
	"multipleOf": optional JInt,

	"^x-": optional patterned anything {},
}.toSchema

# recursion thanks to json schema
SchemaObject["allOf"] = optional SchemaObject.arrayOf

# either a bool, or a SchemaObject
SchemaObject["additionalProperties"] = optional (JBool | SchemaObject)

# this will require some validation logic to assert that keys are valid regex
SchemaObject["properties"] = optional SchemaObject

let Parameter = {
	"name": required JString,
	"in": required JString,
	"description": required JString,
	"required": optional JBool, # default false, required for in=="path"

	# if in is "body", then this is required XXX FIXME
	"schema": optional SchemaObject,
	# otherwise, as per Items:
	"type": required JString,
	"format": optional JString,
	"collectionFormat": optional JString,
	"default": unpatterned optional anything {},
	"maximum": optional JInt,
	"exclusiveMaximum": optional JInt,
	"minimum": optional JInt,
	"exclusiveMinimum": optional JBool,
	"maxLength": optional JInt,
	"minLength": optional JInt,
	"pattern": optional JString,
	"maxItems": optional JInt,
	"minItems": optional JInt,
	"uniqueItems": optional JBool,
	"enum": optional EnumArray,
	"multipleOf": optional JInt,

	# these differ from Items
	"allowEmptyValue": optional JBool,
}.toSchema

let Parameters = (Parameter | Reference).arrayOf

let Header = {
	"type": required JString,

	"format": optional JString,
	"description": optional JString,
	"items": optional Items,
}.toSchema

let Headers = {
	"{name}": patterned Header,
}.toSchema

let Example = {
	"{mimetype}": patterned anything {},
}.toSchema

let Response = {
	"description": required JString,
	"schema": optional SchemaObject,
	"headers": optional Headers,
	"examples": optional Example,
}.toSchema

let Responses = {
	"default": optional (Response | Reference),

	"{httpstatuscode}": optional patterned (Response | Reference),
	"^x-": optional patterned anything {},
}.toSchema

let SchemesArray = JString.arrayOf

let Tag = {
	"name": required JString,
	"description": optional Jstring,
	"externalDocs": optional ExternalDocs,

	"^x-": patterned optional anything {},
}.toSchema

let Operation = {
	"responses": required Responses,

	"tags": optional Tag.arrayOf,
	"summary": optional JString,
	"description": optional JString,
	"externalDocs": optional ExternalDocs,
	"operationId": optional JString,
	"consumes": optional JString.arrayOf,
	"produces": optional JString.arrayOf,
	"parameters": optional Parameters,
	"schemes": optional SchemesArray,
	"deprecated": optional JBool,
	"security": optional SecurityRequirement.arrayOf,

	"^x-": optional patterned anything {},
}.toSchema

let PathItem = {
	"$ref": optional JString,
	"get": optional Operation,
	"put": optional Operation,
	"post": optional Operation,
	"delete": optional Operation,
	"options": optional Operation,
	"head": optional Operation,
	"patch": optional Operation,
	"parameters": optional Parameters,

	"^x-": patterned optional anything {},
}.toSchema

let SecurityScope = {
	"{name}": optional JString,

	"^x-": patterned optional anything {},
}.toSchema

let SecurityScheme = {
	"name": required JString,
	"in": required JString,
	"flow": required JString,
	"authorizationUrl": required JString,
	"tokenUrl": required JString,
	"scopes": required SecurityScope.arrayOf,

	"type": optional JString,
	"description": optional JString,

	"^x-": patterned optional anything {},
}.toSchema

let SecurityDefinitions = {
	"{name}": optional SecurityScheme,
}.toSchema

let Definitions = {
	"{name}": optional SchemaObject,
}.toSchema

let Paths = {
	"/{path}": optional PathItem,

	"^x-": patterned anything {},
}.toSchema

let ParameterDefinition = {
	"{name}": optional Parameter,
}.toSchema

let OpenApi2* = {
	"host": required JString,
	"swagger": required JString,
	"info": required Info,
	"paths": required Paths,

	"consumes": optional JString.arrayOf,
	"produces": optional JString.arrayOf,
	"schemes": optional SchemesArray,

	"basePath": optional JString,
	"definitions": optional Definitions,
	"parameters": optional ParameterDefinition,
	"responses": optional Responses,
	"securityDefinitions": optional SecurityDefinitions,
	"security": optional SecurityRequirement.arrayOf,
	"tag": optional Tag.arrayOf,
	"externalDocs": optional ExternalDocs,

	"^x-": patterned optional anything {},
}.toSchema
