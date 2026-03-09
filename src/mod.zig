//! JSON-RPC 2.0 building blocks.

const types = @import("types.zig");
const codec = @import("codec.zig");
const router = @import("router.zig");
const serde = @import("serde.zig");
const client = @import("client.zig");
const server = @import("server.zig");

pub const VERSION = types.VERSION;
pub const Id = types.Id;
pub const ErrorCode = types.ErrorCode;
pub const ErrorObject = types.ErrorObject;
pub const Request = types.Request;
pub const SuccessResponse = types.SuccessResponse;
pub const ErrorResponse = types.ErrorResponse;
pub const Response = types.Response;

pub const DecodeError = codec.DecodeError;
pub const decodeParams = codec.decodeParams;
pub const decodeResult = codec.decodeResult;
pub const encodeResult = codec.encodeResult;
pub const deinitValue = codec.deinitValue;
pub const cloneValue = codec.cloneValue;

pub const Router = router.Router;
pub const RequestHandler = router.RequestHandler;
pub const NotificationHandler = router.NotificationHandler;
pub const translateError = router.translateError;

pub const ParseError = serde.ParseError;
pub const ParsedRequest = serde.ParsedRequest;
pub const ParsedResponse = serde.ParsedResponse;
pub const ParsedResponseBatch = serde.ParsedResponseBatch;
pub const encodeRequestAlloc = serde.encodeRequestAlloc;
pub const encodeResponseAlloc = serde.encodeResponseAlloc;
pub const parseRequest = serde.parseRequest;
pub const parseResponse = serde.parseResponse;
pub const parseResponseBatch = serde.parseResponseBatch;
pub const encodeRequestBatchAlloc = serde.encodeRequestBatchAlloc;
pub const encodeResponseBatchAlloc = serde.encodeResponseBatchAlloc;
pub const validateRequest = serde.validateRequest;
pub const validateResponse = serde.validateResponse;

pub const Client = client.Client;
pub const AsyncClient = client.AsyncClient;
pub const ClientError = client.ClientError;
pub const Transport = client.Transport;
pub const RemoteError = client.RemoteError;
pub const CallResult = client.CallResult;
pub const BatchResponse = client.BatchResponse;
pub const StartedCall = client.StartedCall;
pub const StartOptions = client.StartOptions;
pub const AsyncCompletion = client.AsyncCompletion;
pub const deinitBatchResponses = client.deinitBatchResponses;

pub const handleBytesAlloc = server.handleBytesAlloc;
pub const errorResponseForRequestFailure = server.errorResponseForRequestFailure;

test {
    @import("std").testing.refAllDecls(@This());
}
