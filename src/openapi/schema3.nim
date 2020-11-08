# Adapted from schema2

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

## An object representing a Server Variable for server URL template substitution.
ServerVariable <~ {
  "default": required JString,

  "enum": optional JString.arrayOf, ## should not be empty
  "description": optional JString,

  "^x-": patterned optional anything {},
}

EnumArray <~ arrayOf(anything {})

ServerObject <~ {
  "url": required JString,

  "description": optional JString,
  "variables": optional ServerVariable.mapOf,

  "^x-": patterned optional anything {},
}

Reference <~ {
  "$ref": required JString,
}

XmlObject <~ {
  "name": optional JString,
  "namespace": optional JString,
  "prefix": optional JString,
  "attribute": optional JBool,
  "wrapped": optional JBool,

  "^x-": optional patterned anything {},
}

ExternalDocs <~ {
  "url": required JString,

  "description": optional JString,

  "^x-": patterned anything {},
}

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
  "required": optional JString.arrayOf,
  "enum": optional EnumArray,
  "multipleOf": optional JInt,

  "^x-": optional patterned anything {},
}


ParameterObject <~ {
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

  "name": required JString,
  "in": required JString,
}

Header <~ {
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

Headers <~ {
  "{name}": optional Header,
}

ExampleObject <~ {
  "summary": optional JString,
  "description": optional JString,
  "value": optional anything(),
  "externalValue": optional JString,
}

Response <~ {
  "description": required JString,
  "schema": optional SchemaObject,
  "headers": optional Headers,
  "examples": optional ExampleObject,
}

Responses <~ {
  "default": optional (Response | Reference),

  "{http status code}": optional (Response | Reference),
  "^x-": optional patterned anything {},
}


## Holds a set of reusable objects for different aspects of the OAS.
## All objects defined within the components object will have no effect on the
## API unless they are explicitly referenced from properties outside the components object.
Components <~ {
  "schemas": (SchemaObject | Reference).mapOf,
  "responses": (Response | Reference).mapOf,

}

# recursive type in case the parent type is array, in which
# case this field reflects the type of array members
static:
  Items["items"] = optional Items

static:
  # recursion thanks to json schema
  SchemaObject["allOf"] = optional SchemaObject.arrayOf

  # either a bool, or a SchemaObject; these are table semantics
  SchemaObject["additionalProperties"] = optional (JBool | SchemaObject)

  # these are basic object field semantics; arbitrary values
  SchemaObject["properties"] = optional SchemaObject

SecurityRequirement <~ {
  "{name}": optional JString.arrayOf,
}

Example <~ {
  "{mime type}": optional anything {},
}

SchemesArray <~ JString.arrayOf

TagObject <~ {
  "name": required JString,
  "description": optional Jstring,
  "externalDocs": optional ExternalDocs,

  "^x-": patterned optional anything {},
}

EncodingObject <~ {
  "contentType": optional JString,
  "headers": optional (Header | Reference).mapOf,
  "style": optional JString,
  "explode": optional JBool,
  "allowReserved": optional JBool,

  "^x-": patterned optional anything {},
}

MediaTypeObject <~ {
  "encoding": optional EncodingObject.mapOf,
  "example": optional anything(),
  "schema": optional (SchemaObject | Reference),
  "examples": optional (ExampleObject | Reference).mapOf,

  "^x-": optional patterned anything {},
}

RequestBodyObject <~ {
  "content": required MediaTypeObject.mapOf,

  "description": optional JString,
  "required": optional JBool,

  "^x-": patterned optional anything {},
}

ParameterObjectDefinition <~ {
  "{name}": optional ParameterObject,
}

Operation <~ {
  "responses": required Responses,

  "tags": optional TagObject.arrayOf,
  "summary": optional JString,
  "description": optional JString,
  "externalDocs": optional ExternalDocs,
  "operationId": optional JString,
  "consumes": optional JString.arrayOf,
  "produces": optional JString.arrayOf,
  "parameters": optional (ParameterObject | Reference).arrayOf,
  "requestBody": optional (RequestBodyObject | Reference),
  # "schemes": optional SchemesArray,
  "deprecated": optional JBool,
  "security": optional SecurityRequirement.arrayOf,
  "servers": optional ServerObject.arrayOf,

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
  "parameters": optional (ParameterObject | Reference).arrayOf,

  "^x-": patterned optional anything {},
}

CallbackObject <~ {
  "{expression}": required PathItem,
}

# break recursion
static:
  Operation["callbacks"] = optional (CallbackObject | Reference).mapOf

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

OpenApi3 <~ {
  "openapi": required JString,
  "info": required Info,
  "paths": required Paths,
  "servers": optional ServerObject.arrayOf,
  "components": optional Components,
  "security": optional SecurityRequirement.arrayOf,
  "tags": optional TagObject.arrayOf,
  "externalDocs": optional ExternalDocs,

  "^x-": patterned optional anything {},
}
export OpenApi3
