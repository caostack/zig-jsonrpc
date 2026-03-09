# jsonrpc

`packages/jsonrpc` is a JSON-RPC 2.0 protocol package for Zig `0.15.2`.

It provides:

- Core JSON-RPC 2.0 types
- Typed params/result codec on top of `std.json.Value`
- Strict request/response serializer and parser
- Method router for server-side dispatch
- Raw-bytes server entrypoint with standard error responses
- Synchronous client and transport-agnostic async client state machine
- Single-call and batch-call support

## Standards Scope

Implemented:

- JSON-RPC `2.0` version validation
- Request, notification, success response, error response
- Standard error codes and custom server error codes
- Batch request and batch response handling
- Standard parse error / invalid request generation on raw server input
- Reserved method-name rejection for names starting with `rpc.`

Current design choice:

- Params must be object or array when present. `params: null` is rejected by serializer and parser.

## Module Overview

- `types.zig`: protocol types
- `codec.zig`: typed decode/encode and JSON value ownership helpers
- `serde.zig`: strict serialization/parsing
- `router.zig`: handler registry and dispatch
- `server.zig`: raw-bytes server pipeline
- `client.zig`: synchronous client plus async pending/completion state machine

## Memory Ownership

- `encodeResult` returns `std.json.Value` owned by the caller. Release it with `deinitValue`.
- `parseRequest`, `parseResponse`, and `parseResponseBatch` return parsed wrappers. Their embedded strings/values are valid until `deinit()`.
- `Client.callBatch` returns cloned responses owned by the caller. Release them with `deinitBatchResponses`.
- `AsyncClient.takeCompletion` transfers ownership of the returned completion to the caller. Call `completion.deinit(allocator)` for `.response`.
- `RemoteError` owns `message` and optional `data`. Release with `RemoteError.deinit`.

## Client Models

### `Client`

Use when transport is synchronous request/response:

- `call`
- `notify`
- `callBatch`
- `notifyBatch`

### `AsyncClient`

Use when transport is external or event-driven:

- `startCall` allocates request bytes and registers the pending request
- `acceptResponseBytes` matches incoming single/batch responses to pending requests
- `cancel` marks a pending request as cancelled
- `expireTimeouts` marks overdue pending requests as timed out
- `takeCompletion` retrieves a completed response/cancel/timeout result

`AsyncClient` generates numeric ids internally and expects response ids to match those numeric ids.

## Quality Gates

Run:

```bash
zig build test
zig build quality
```
