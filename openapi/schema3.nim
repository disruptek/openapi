# openapi 3.0 schema definition
import tables

import spec
import schemadsl

Contact3 <~ {
  "name": optional JString,
  "url": optional JString,
  "email": optional JString,

  "^x-": patterned optional anything {},
}

License3 <~ {
  "name": required JString,

  "url": optional JString,

  "^x-": patterned optional anything {},
}

Info3 <~ {
  "title": required JString,
  "version": required JString,

  "description": optional JString,
  "termsOfService": optional JString,
  "contact": optional Contact3,
  "license": optional License3,

  "^x-": patterned optional anything {},
}

Reference3 <~ {
  "$ref": required JString,
}

ExternalDocs3 <~ {
  "url": required JString,

  "description": optional JString,

  "^x-": patterned anything {},
}

SecurityRequirement3 <~ {
  "{name}": optional JString.arrayOf,
}

ServerVariable <~ {
  "default": required JString,

  "enum": optional JString.arrayOf,
  "description": optional JString,

  "^x-": patterned optional anything {},
}

ServerVariables <~ {
  "{name}": optional ServerVariable,
}

Server <~ {
  "url": required JString,

  "description": optional JString,
  "variables": optional ServerVariables,

  "^x-": patterned optional anything {},
}

XmlObject3 <~ {
  "name": optional JString,
  "namespace": optional JString,
  "prefix": optional JString,
  "attribute": optional JBool,
  "wrapped": optional JBool,

  "^x-": optional patterned anything {},
}

EnumArray3 <~ arrayOf(anything {})

DiscriminatorMapping <~ {
  "{name}": optional JString,
}

Discriminator3 <~ {
  "propertyName": required JString,

  "mapping": optional DiscriminatorMapping,

  "^x-": patterned optional anything {},
}

SchemaObject3 <~ {
  "$ref": optional Reference3,

  "type": optional JString,
  "format": optional JString,
  "title": optional JString,
  "description": optional JString,
  "default": optional anything {},
  "multipleOf": optional JInt,
  "nullable": optional JBool,

  "discriminator": optional Discriminator3,
  "readOnly": optional JBool,
  "writeOnly": optional JBool,
  "xml": optional XmlObject3,
  "externalDocs": optional ExternalDocs3,
  "example": optional unpatterned anything {},
  "deprecated": optional JBool,

  # from items/array
  "items": optional anything {},  # recursive; patched below
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

  "maxProperties": optional JInt,
  "minProperties": optional JInt,
  "required": optional JString.arrayOf,
  "enum": optional EnumArray3,

  "^x-": optional patterned anything {},
}

static:
  SchemaObject3["allOf"] = optional SchemaObject3.arrayOf
  SchemaObject3["oneOf"] = optional SchemaObject3.arrayOf
  SchemaObject3["anyOf"] = optional SchemaObject3.arrayOf
  SchemaObject3["not"] = optional SchemaObject3
  SchemaObject3["items"] = optional SchemaObject3

  SchemaObject3["additionalProperties"] = optional (JBool | SchemaObject3)
  SchemaObject3["properties"] = optional SchemaObject3

MediaType3 <~ {
  "schema": optional SchemaObject3,
  "example": optional unpatterned anything {},

  "^x-": patterned optional anything {},
}

Content3 <~ {
  "{media type}": optional MediaType3,
}

# oa3 parameters never use in=body; they always have schema
Parameter3 <~ {
  "name": required JString,
  "in": required JString,

  "description": optional JString,
  "required": optional JBool,
  "deprecated": optional JBool,
  "allowEmptyValue": optional JBool,

  "schema": optional SchemaObject3,
  "style": optional JString,
  "explode": optional JBool,
  "allowReserved": optional JBool,
  "example": optional unpatterned anything {},
  "content": optional Content3,

  "^x-": optional patterned anything {},
}

Parameters3 <~ (Parameter3 | Reference3).arrayOf

RequestBody3 <~ {
  "content": required Content3,

  "description": optional JString,
  "required": optional JBool,

  "^x-": patterned optional anything {},
}

Header3 <~ {
  "description": optional JString,
  "required": optional JBool,
  "deprecated": optional JBool,
  "schema": optional SchemaObject3,

  "^x-": optional patterned anything {},
}

Headers3 <~ {
  "{name}": optional (Header3 | Reference3),
}

Link3 <~ {
  "operationRef": optional JString,
  "operationId": optional JString,
  "description": optional JString,

  "^x-": patterned optional anything {},
}

Links3 <~ {
  "{name}": optional (Link3 | Reference3),
}

Response3 <~ {
  "description": required JString,

  "headers": optional Headers3,
  "content": optional Content3,
  "links": optional Links3,

  "^x-": patterned optional anything {},
}

Responses3 <~ {
  "default": optional (Response3 | Reference3),

  "{http status code}": optional (Response3 | Reference3),
  "^x-": optional patterned anything {},
}

Tag3 <~ {
  "name": required JString,
  "description": optional JString,
  "externalDocs": optional ExternalDocs3,

  "^x-": patterned optional anything {},
}

Operation3 <~ {
  "responses": required Responses3,

  "tags": optional JString.arrayOf,
  "summary": optional JString,
  "description": optional JString,
  "externalDocs": optional ExternalDocs3,
  "operationId": optional JString,
  "parameters": optional Parameters3,
  "requestBody": optional (RequestBody3 | Reference3),
  "deprecated": optional JBool,
  "security": optional SecurityRequirement3.arrayOf,
  "servers": optional Server.arrayOf,

  "^x-": optional patterned anything {},
}

PathItem3 <~ {
  "$ref": optional JString,
  "summary": optional JString,
  "description": optional JString,
  "get": optional Operation3,
  "put": optional Operation3,
  "post": optional Operation3,
  "delete": optional Operation3,
  "options": optional Operation3,
  "head": optional Operation3,
  "patch": optional Operation3,
  "trace": optional Operation3,
  "parameters": optional Parameters3,
  "servers": optional Server.arrayOf,

  "^x-": patterned optional anything {},
}

Paths3 <~ {
  "/{path}": optional PathItem3,

  "^x-": patterned anything {},
}

# oauth flow objects
OAuthFlow3 <~ {
  "authorizationUrl": optional JString,
  "tokenUrl": optional JString,
  "refreshUrl": optional JString,
  "scopes": optional anything {},

  "^x-": patterned optional anything {},
}

OAuthFlows3 <~ {
  "implicit": optional OAuthFlow3,
  "password": optional OAuthFlow3,
  "clientCredentials": optional OAuthFlow3,
  "authorizationCode": optional OAuthFlow3,

  "^x-": patterned optional anything {},
}

SecurityScheme3 <~ {
  "type": required JString,

  "description": optional JString,
  "name": optional JString,
  "in": optional JString,
  "scheme": optional JString,
  "bearerFormat": optional JString,
  "flows": optional OAuthFlows3,
  "openIdConnectUrl": optional JString,

  "^x-": patterned optional anything {},
}

Schemas3 <~ {
  "{name}": optional SchemaObject3,
}

Components3 <~ {
  "schemas": optional Schemas3,
  "responses": optional anything {},
  "parameters": optional anything {},
  "examples": optional anything {},
  "requestBodies": optional anything {},
  "headers": optional anything {},
  "securitySchemes": optional anything {},
  "links": optional anything {},
  "callbacks": optional anything {},

  "^x-": patterned optional anything {},
}

OpenApi3 <~ {
  "openapi": required JString,
  "info": required Info3,
  "paths": required Paths3,

  "servers": optional Server.arrayOf,
  "components": optional Components3,
  "security": optional SecurityRequirement3.arrayOf,
  "tags": optional Tag3.arrayOf,
  "externalDocs": optional ExternalDocs3,

  "^x-": patterned optional anything {},
}
export OpenApi3
