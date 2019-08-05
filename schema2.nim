#? replace(sub = "\t", by = " ")
# this is rather critical for reasons
import tables

import spec


template `<~`(name: untyped; fields: openArray[(FieldName, FieldTypeDef)]) =
	# it's a var because we sometimes need to mutate it
	var name {.compileTime.} = `fields`.newSchema

template `<~`(name: untyped; ftype: FieldTypeDef) =
	# it's a var because we sometimes need to mutate it
	var name {.compileTime.} = ftype

Contact <~ {
	"name": optional JString,
	"url": optional JString,
	"email": optional JString,

	"^x-": patterned optional anything {},
}

License <~ {
	"name": required JString,

	"url": optional JString,

	"^x-": patterned optional anything {},
}

Info <~ {
	"title": required JString,
	"version": required JString,

	"description": optional JString,
	"termsOfService": optional JString,
	"contact": optional Contact,
	"license": optional License,

	"^x-": patterned optional anything {},
}

Reference <~ {
	"$ref": required JString,
}

ExternalDocs <~ {
	"url": required JString,

	"description": optional JString,

	"^x-": patterned anything {},
}

SecurityRequirement <~ {
	"{name}": optional JString.arrayOf,
}

XmlObject <~ {
	"name": optional JString,
	"namespace": optional JString,
	"prefix": optional JString,
	"attribute": optional JBool,
	"wrapped": optional JBool,

	"^x-": optional patterned anything {},
}

# enum values could be literally anything.
# not sure we can validate them beyond the guarantees json provides...
EnumArray <~ arrayOf(anything {})

Items <~ {
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
}

# recursive type in case the parent type is array, in which
# case this field reflects the type of array members
static:
	Items["items"] = optional Items

SchemaObject <~ {
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
}

static:
	# recursion thanks to json schema
	SchemaObject["allOf"] = optional SchemaObject.arrayOf

	# either a bool, or a SchemaObject
	SchemaObject["additionalProperties"] = optional (JBool | SchemaObject)

	# this will require some validation logic to assert that keys are valid regex
	SchemaObject["properties"] = optional SchemaObject

Parameter <~ {
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
}

Parameters <~ (Parameter | Reference).arrayOf

Header <~ {
	"type": required JString,

	"format": optional JString,
	"description": optional JString,
	"items": optional Items,
}

Headers <~ {
	"{name}": optional Header,
}

Example <~ {
	"{mime type}": optional anything {},
}

Response <~ {
	"description": required JString,
	"schema": optional SchemaObject,
	"headers": optional Headers,
	"examples": optional Example,
}

Responses <~ {
	"default": optional (Response | Reference),

	"{http status code}": optional (Response | Reference),
	"^x-": optional patterned anything {},
}

SchemesArray <~ JString.arrayOf

Tag <~ {
	"name": required JString,
	"description": optional Jstring,
	"externalDocs": optional ExternalDocs,

	"^x-": patterned optional anything {},
}

Operation <~ {
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
}

PathItem <~ {
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
}

SecurityScope <~ {
	"{name}": optional JString,

	"^x-": patterned optional anything {},
}

SecurityScheme <~ {
	"name": required JString,
	"in": required JString,
	"flow": required JString,
	"authorizationUrl": required JString,
	"tokenUrl": required JString,
	"scopes": required SecurityScope.arrayOf,

	"type": optional JString,
	"description": optional JString,

	"^x-": patterned optional anything {},
}

SecurityDefinitions <~ {
	"{name}": optional SecurityScheme,
}

Definitions <~ {
	"{name}": optional SchemaObject,
}

Paths <~ {
	"/{path}": optional PathItem,

	"^x-": patterned anything {},
}

ParameterDefinition <~ {
	"{name}": optional Parameter,
}

OpenApi2 <~ {
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
	"tags": optional Tag.arrayOf,
	"externalDocs": optional ExternalDocs,

	"^x-": patterned optional anything {},
}
export OpenApi2
