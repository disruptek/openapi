import std/json
import std/options
import std/strutils
import std/uri

import pkg/openapi/spec
import pkg/openapi/parser
from pkg/openapi/schema3 import OpenApi3

const
  petstore3 = staticRead("petstore3.json")

static:
  echo "parse openapi 3.0 petstore spec against schema"
  let js = petstore3.parseJson()
  let pr = OpenApi3.parseSchema(js)
  assert pr.ok, "schema3 parse failed: " & $pr

  echo "detect openapi version"
  assert "openapi" in js
  assert js["openapi"].getStr == "3.0.0"
  assert js["openapi"].getStr.startsWith("3.")

  echo "version detection distinguishes v2 from v3"
  assert "swagger" notin js
  let v2js = %* {
    "swagger": "2.0",
    "info": {"title": "x", "version": "1"},
    "host": "example.com",
    "paths": {},
    "schemes": ["http"]
  }
  assert "swagger" in v2js and "openapi" notin v2js

  echo "extract server info"
  assert "servers" in js
  assert js["servers"].kind == JArray
  assert js["servers"].len == 1
  let serverUrl = js["servers"][0]["url"].getStr
  assert serverUrl == "http://petstore.swagger.io/v1"
  # verify we can parse scheme, host, basePath from server url
  let parsed = parseUri(serverUrl)
  assert parsed.scheme == "http"
  assert parsed.hostname == "petstore.swagger.io"
  assert parsed.path == "/v1"

  echo "extract paths"
  assert "/pets" in js["paths"]
  assert "/pets/{petId}" in js["paths"]

  echo "extract operations"
  let pets = js["paths"]["/pets"]
  assert "get" in pets
  assert "post" in pets
  let getPets = pets["get"]
  assert getPets["operationId"].getStr == "listPets"

  echo "extract oa3 parameters with schema"
  let params = getPets["parameters"]
  assert params.kind == JArray and params.len == 1
  let limit = params[0]
  assert limit["name"].getStr == "limit"
  assert limit["in"].getStr == "query"
  assert "schema" in limit
  assert limit["schema"]["type"].getStr == "integer"
  # key oa3 difference: type is on schema, not on parameter
  assert "type" notin limit

  echo "guess type from oa3 schema-based parameter"
  let limitKind = limit.guessType(js)
  assert limitKind.isSome
  assert limitKind.get.major == JInt

  echo "extract requestBody"
  let postPets = pets["post"]
  assert "requestBody" in postPets
  let rb = postPets["requestBody"]
  assert rb["required"].getBool == true
  assert "content" in rb
  assert "application/json" in rb["content"]
  let rbSchema = rb["content"]["application/json"]["schema"]
  assert "$ref" in rbSchema
  assert rbSchema["$ref"].getStr == "#/components/schemas/Pet"

  echo "resolve component refs via pluckRefJson"
  assert "components" in js
  assert "schemas" in js["components"]
  let pet = js.pluckRefJson(rbSchema)
  assert pet != nil
  assert pet["type"].getStr == "object"
  assert "properties" in pet
  assert "id" in pet["properties"]

  echo "guessType follows component refs"
  let refKind = rbSchema.guessType(js)
  assert refKind.isSome
  assert refKind.get.major == JObject

  echo "extract path parameter"
  let petById = js["paths"]["/pets/{petId}"]
  let pathParam = petById["get"]["parameters"][0]
  assert pathParam["name"].getStr == "petId"
  assert pathParam["in"].getStr == "path"
  assert pathParam["required"].getBool == true
  assert pathParam["schema"]["type"].getStr == "string"
  let pathParamKind = pathParam.guessType(js)
  assert pathParamKind.isSome
  assert pathParamKind.get.major == JString

  echo "extract delete operation"
  assert "delete" in petById
  let deletePet = petById["delete"]
  assert deletePet["operationId"].getStr == "deletePet"

  echo "oa3 responses use content/media-type/schema"
  let getResp = getPets["responses"]["200"]
  assert "content" in getResp
  assert "application/json" in getResp["content"]
  let respSchema = getResp["content"]["application/json"]["schema"]
  assert "$ref" in respSchema
  let resolvedResp = js.pluckRefJson(respSchema)
  assert resolvedResp != nil
  assert resolvedResp["type"].getStr == "array"

  echo "all openapi 3 tests passed"
