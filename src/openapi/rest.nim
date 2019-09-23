import os
import times
import deques
import sequtils
import httpclient
import httpcore
import asyncdispatch
import json
import xmltree
import logging
import strutils
import uri

import foreach

export httpcore.HttpMethod, is2xx, is3xx, is4xx, is5xx

type
  KeyVal = tuple[key: string; val: string]
  ResultFormat* = enum JSON, XML, RAW

  JsonResultPage* = JsonNode
  JsonPageFuture* = Future[JsonResultPage]

  XmlResultPage* = XmlNode
  XmlPageFuture* = Future[XmlResultPage]

  RawResultPage* = string
  RawPageFuture* = Future[RawResultPage]

  ResultPage* = JsonResultPage | XmlResultPage | RawResultPage
  PageFuture* = Future[ResultPage]

  RestClientObj = object of RootObj
    keepalive: bool
    http: AsyncHttpClient
    headers: HttpHeaders
  RestClient* = ref RestClientObj

  RestCall* = ref object of RootObj
    client*: RestClient
    name*: string
    meth*: HttpMethod

  FutureQueueFifo* = Deque
  PageFuturesFifo*[T] = Deque[T]

  FutureQueueSeq* = seq
  PageFuturesSeq*[T] = seq[T]

  Recallable* = ref object of RootObj
    ## a handle on input/output of a re-issuable API call
    headers*: HttpHeaders
    client*: RestClient
    url*: string
    json*: JsonNode
    body*: string
    retries*: int
    began*: Time
    took*: Duration
    meth*: HttpMethod
  RestError* = object of CatchableError       ## base for REST errors
  AsyncError* = object of RestError           ## undefined async error
  RetriesExhausted* = object of RestError     ## ran outta retries
  CallRequestError* = object of RestError     ## HTTP [45]00 status code

proc massageHeaders*(node: JsonNode): seq[KeyVal] =
  if node == nil or node.kind != JObject or node.len == 0:
    return
  foreach k, v in node.pairs of string and JsonNode:
    assert v.kind == JString
    result.add (key: k, val: v.getStr)

iterator fibonacci*(start=0; stop=0): int {.raises: [].} =
  var
    y = if start == 0: 1 else: start
    x = start
  while stop == 0 or y <= stop:
    yield y
    (x, y) = (y, x + y)

template accumulator(iter: untyped) =
  for element in iter:
    result.add(element)

proc fibonacci*(start=0; stop=0): seq[int] {.raises: [].} =
  accumulator(fibonacci(start, stop))

proc add*[T](futures: var PageFuturesFifo[T], value: PageFuture)
  {.raises: [].} =
  futures.addLast(value)

method `$`*(e: ref RestError): string
  {.base, raises: [].}=
  result = $typeof(e) & " " & e.msg

method `$`*(c: RestCall): string
  {.base, raises: [].}=
  result = $c.meth
  result = result.toUpperAscii & " " & c.name

method initRestClient*(self: RestClient) {.base.} =
  self.http = newAsyncHttpClient()

proc newRestClient*(): RestClient =
  new result
  result.initRestClient()

method newRecallable*(call: RestCall; url: Uri; headers: HttpHeaders;
                      body: string): Recallable
  {.base,raises: [Exception].} =
  ## make a new HTTP request that we can reissue if desired
  new result
  result.url = $url
  result.retries = 0
  result.body = body
  #
  # TODO: disambiguate responses to requests?
  #
  if call.client != nil and call.client.keepalive:
    result.client = call.client
  else:
    result.client = newRestClient()
  result.headers = headers
  result.client.headers = result.headers
  result.client.http.headers = result.headers
  result.meth = call.meth

method newRecallable*(call: RestCall; url: string; headers: HttpHeaders;
                      body: string): Recallable
  {.base,raises: [Exception].} =
  ## make a new HTTP request that we can reissue if desired
  result = newRecallable(call, url.parseUri, headers, body)

method newRecallable*(call: RestCall; url: Uri; headers: openArray[KeyVal];
                      body: string): Recallable
  {.base,raises: [Exception].} =
  ## make a new HTTP request that we can reissue if desired
  let heads = newHttpHeaders(headers)
  result = newRecallable(call, url, heads, body)

method newRecallable*(call: RestCall; url: Uri; headers: JsonNode;
                      body: JsonNode): Recallable
  {.base,raises: [Exception].} =
  ## make a new HTTP request that we can reissue if desired
  let
    heads = headers.massageHeaders
  var
    content: string
  if body != nil:
    toUgly(content, body)
  result = newRecallable(call, url, heads, content)

method newRecallable*(call: RestCall; url: Uri; input: JsonNode): Recallable
  {.base,raises: [Exception].} =
  ## make a new HTTP request that we can reissue if desired
  let
    heads = input.getOrDefault("header")
    body = input.getOrDefault("body")
  result = newRecallable(call, url, heads, body)

method newRecallable*(call: RestCall; url: Uri): Recallable
  {.base,raises: [Exception].} =
  ## make a new HTTP request that we can reissue if desired
  result = newRecallable(call, url, newHttpHeaders(), "")

# a hack to work around nim 0.20 -> 1.0 interface change
template isEmptyAnyVersion(h: HttpHeaders): bool =
  when compiles(h.isEmpty):
    h.isEmpty
  else:
    h == nil

proc issueRequest*(rec: Recallable): Future[AsyncResponse]
  {.raises: [AsyncError].} =
  ## submit a request and store some metrics
  assert rec.client != nil
  try:
    if rec.body == "":
      if rec.json != nil:
        rec.body = $rec.json
    rec.began = getTime()
    #
    # FIXME move this header-fu into something restClient-specific
    #
    if not rec.headers.isEmptyAnyVersion:
      rec.client.http.headers = rec.headers
    elif not rec.client.headers.isEmptyAnyVersion:
      rec.client.http.headers = rec.client.headers
    else:
      rec.client.http.headers = newHttpHeaders()
    result = rec.client.http.request(rec.url, rec.meth, body=rec.body)
  except CatchableError as e:
    raise newException(AsyncError, e.msg)
  except Exception as e:
    raise newException(AsyncError, e.msg)

proc retried*(rec: Recallable; tries=5; ms=1000): AsyncResponse
  {.raises: [RestError].} =
  ## issue the call and return the response synchronously;
  ## raises in the event of a failure
  try:
    foreach fib in fibonacci(0, tries) of int:
      result = waitfor rec.issueRequest()
      if result.code.is2xx:
        return
      if result.code.is4xx:
        error waitfor result.body
        raise newException(CallRequestError, result.status)
      warn $result.status & "; sleeping " & $fib & " secs and retrying..."
      sleep fib * ms
      rec.retries.inc
  except RestError as e:
    raise e
  except CatchableError as e:
    raise newException(AsyncError, e.msg)
  except Exception as e:
    raise newException(AsyncError, e.msg)
  raise newException(RetriesExhausted, "Exhausted " & $tries & " retries")

proc retry*(rec: Recallable; tries=5; ms=1000): Future[AsyncResponse]
  {.async.} =
  ## try to issue the call and return the response; only
  ## retry if the status code is 1XX, 3XX, or 5XX.
  var response: AsyncResponse
  try:
    foreach fib in fibonacci(0, tries) of int:
      response = await rec.issueRequest()
      if response.code.is2xx:
        return response
      if response.code.is4xx:
        raise newException(CallRequestError, response.status)
      warn $response.status & "; sleeping " & $fib & " secs and retrying..."
      await sleepAsync(fib * ms)
      rec.retries.inc
  except RestError as e:
    raise e
  except CatchableError as e:
    raise newException(AsyncError, e.msg)
  except Exception as e:
    raise newException(AsyncError, e.msg)
  if true:
    raise newException(RetriesExhausted, "Exhausted " & $tries & " retries")

iterator retried*(rec: Recallable; tries=5; ms=1000): AsyncResponse
  {.raises: [RestError].} =
  ## synchronously do something every time the response comes back;
  ## the iterator does not terminate if the request was successful;
  ## obviously, you can terminate early.
  var response: AsyncResponse
  try:
    foreach fib in fibonacci(0, tries) of int:
      response = waitfor rec.issueRequest()
      yield response
      if response.code.is4xx:
        raise newException(CallRequestError, response.status)
      warn $response.status & "; sleeping " & $fib & " secs and retrying..."
      sleep(fib * ms)
      rec.retries.inc
  except RestError as e:
    raise e
  except CatchableError as e:
    raise newException(AsyncError, e.msg)
  except Exception as e:
    raise newException(AsyncError, e.msg)

proc errorFree*[T: RestCall](rec: Recallable; call: T; tries=5; ms=1000):
  Future[string]
  {.async.} =
  ## issue and re-issue a recallable until it yields a response
  var
    response: AsyncResponse
    text: string
    limit = tries
  while true:
    try:
      response = await rec.retry(tries=limit, ms=ms)
      rec.took = getTime() - rec.began
      if not response.code.is2xx:
        warn $call & " failed after " & $rec.retries & " retries"
        limit -= rec.retries
        continue
      return await response.body
    except RestError as e:
      raise e
    except CatchableError as e:
      raise newException(AsyncError, e.msg)
    except Exception as e:
      raise newException(AsyncError, e.msg)
    finally:
      rec.took = getTime() - rec.began
      info $call & " total request " & $rec.took

proc first*[T](futures: openarray[Future[T]]): Future[T]
  {.raises: [Defect, Exception].} =
  ## wait for any of the input futures to complete; return the first
  assert futures.len != 0
  case futures.len:
  of 0:
    raise newException(Defect, "first called without futures")
  of 1:
    result = futures[futures.low]
  else:
    var future = newFuture[T]("first")
    proc anycb[T](promise: Future[T])
      {.raises: [Exception].} =
      if future.finished:
        return
      if promise.failed:
        future.fail(promise.error)
      else:
        future.complete(promise.read)
    for vow in futures.items:
      vow.addCallback anycb[T]
    result = future

iterator ready*[T](futures: var PageFuturesSeq[T]; threads=0): T
  {.raises: [Exception]} =
  ## iteratively drain a queue of futures with limited concurrency
  var ready: PageFuturesSeq[T]
  while futures.len > 0:
    ready = futures.filterIt(it.finished)
    futures.keepItIf(not it.finished)
    if ready.len == 0:
      if futures.len <= threads:
        break
      discard waitfor futures.first
      continue
    else:
      debug "futures ready: " & $ready.len & " unready: " & $futures.len
    for vow in ready.items:
      if vow.failed:
        raise vow.error
      yield vow


when isMainModule:
  import unittest

  suite "rest":
    type
      TestCall = ref object of RestCall

    const URL = "http://www.google.com/"

    setup:
      var
        call = TestCall(meth: HttpGet)
        rec = call.newRecallable(URL.parseUri)

    teardown:
      notice "(latency of below test)"

    test "retried via procs":
      var response = rec.retried()
      check response.code.is2xx
      var text = waitfor response.body
      check text != ""

    test "retried via iteration":
      var text: string
      foreach response in rec.retried(tries=5) of AsyncResponse:
        if not response.code.is2xx:
          warn "retried " & $rec.retries & " took " & $rec.took
          continue
        text = waitfor response.body
        check text != ""
        break

    test "async retry":
      var response = waitfor rec.retry()
      check response.code.is2xx
      var text = waitfor response.body
      check text != ""
