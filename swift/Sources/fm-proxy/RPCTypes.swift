import Foundation

// MARK: - Request

struct RPCRequest: Codable {
    let id: String?
    let method: String
    let params: RPCParams?
}

enum RPCParams: Codable {
    case responsesCreate(ResponsesCreateParams)
    case responsesCancel(ResponsesCancelParams)
    case empty
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        // Decode based on which required fields are present
        // ResponsesCreateParams requires "input", ResponsesCancelParams requires "request_id"
        if let createParams = try? container.decode(ResponsesCreateParams.self) {
            self = .responsesCreate(createParams)
        } else if let cancelParams = try? container.decode(ResponsesCancelParams.self), !cancelParams.requestId.isEmpty {
            self = .responsesCancel(cancelParams)
        } else {
            self = .empty
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .responsesCreate(let params):
            try container.encode(params)
        case .responsesCancel(let params):
            try container.encode(params)
        case .empty:
            try container.encodeNil()
        }
    }
}

struct ResponsesCreateParams: Codable {
    let input: String
    let maxOutputTokens: Int?
    let stream: Bool?
    let responseFormat: ResponseFormat?
    
    enum CodingKeys: String, CodingKey {
        case input
        case maxOutputTokens = "max_output_tokens"
        case stream
        case responseFormat = "response_format"
    }
}

struct ResponseFormat: Codable {
    let type: String  // "json_schema"
    let jsonSchema: JSONSchemaSpec?
    
    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }
}

struct JSONSchemaSpec: Codable {
    let name: String
    let description: String?
    let schema: JSONSchemaNode
}

// Recursive JSON Schema representation
indirect enum JSONSchemaNode: Codable {
    case object(properties: [String: JSONSchemaNode], required: [String]?, description: String?)
    case array(items: JSONSchemaNode, description: String?)
    case string(description: String?, enumValues: [String]?)
    case number(description: String?)
    case integer(description: String?)
    case boolean(description: String?)
    
    enum CodingKeys: String, CodingKey {
        case type, properties, required, items, description
        case enumValues = "enum"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let description = try container.decodeIfPresent(String.self, forKey: .description)
        
        switch type {
        case "object":
            let props = try container.decodeIfPresent([String: JSONSchemaNode].self, forKey: .properties) ?? [:]
            let required = try container.decodeIfPresent([String].self, forKey: .required)
            self = .object(properties: props, required: required, description: description)
        case "array":
            let items = try container.decode(JSONSchemaNode.self, forKey: .items)
            self = .array(items: items, description: description)
        case "string":
            let enumVals = try container.decodeIfPresent([String].self, forKey: .enumValues)
            self = .string(description: description, enumValues: enumVals)
        case "number":
            self = .number(description: description)
        case "integer":
            self = .integer(description: description)
        case "boolean":
            self = .boolean(description: description)
        default:
            self = .string(description: description, enumValues: nil)
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .object(let properties, let required, let description):
            try container.encode("object", forKey: .type)
            try container.encode(properties, forKey: .properties)
            try container.encodeIfPresent(required, forKey: .required)
            try container.encodeIfPresent(description, forKey: .description)
        case .array(let items, let description):
            try container.encode("array", forKey: .type)
            try container.encode(items, forKey: .items)
            try container.encodeIfPresent(description, forKey: .description)
        case .string(let description, let enumValues):
            try container.encode("string", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encodeIfPresent(enumValues, forKey: .enumValues)
        case .number(let description):
            try container.encode("number", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)
        case .integer(let description):
            try container.encode("integer", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)
        case .boolean(let description):
            try container.encode("boolean", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)
        }
    }
}

struct ResponsesCancelParams: Codable {
    let requestId: String
    
    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
    }
}

// MARK: - Response

struct RPCResponse: Codable {
    let id: String?
    let ok: Bool
    let result: RPCResult?
    let error: RPCError?
    
    static func success(id: String?, result: RPCResult) -> RPCResponse {
        RPCResponse(id: id, ok: true, result: result, error: nil)
    }
    
    static func error(id: String?, code: String, detail: String) -> RPCResponse {
        RPCResponse(id: id, ok: false, result: nil, error: RPCError(code: code, detail: detail))
    }
}

struct RPCError: Codable {
    let code: String
    let detail: String
}

enum RPCResult: Codable {
    case ping(PingResult)
    case capabilities(CapabilitiesResult)
    case response(ResponseResult)
    case streamEvent(StreamEvent)
    case empty
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .ping(let result):
            try container.encode(result)
        case .capabilities(let result):
            try container.encode(result)
        case .response(let result):
            try container.encode(result)
        case .streamEvent(let event):
            try container.encode(event)
        case .empty:
            try container.encode([String: String]())
        }
    }
    
    init(from decoder: Decoder) throws {
        // Default to empty for decoding (we mostly encode)
        self = .empty
    }
}

// MARK: - Result Types

struct PingResult: Codable {
    let ok: Bool
    let protocolVersion: Int
    
    enum CodingKeys: String, CodingKey {
        case ok
        case protocolVersion = "protocol_version"
    }
}

struct CapabilitiesResult: Codable {
    let available: Bool
    let reasonCode: String?
    let model: String?
    
    enum CodingKeys: String, CodingKey {
        case available
        case reasonCode = "reason_code"
        case model
    }
}

struct ResponseResult: Codable {
    let requestId: String
    let text: String
    
    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case text
    }
}

struct StreamEvent: Codable {
    let requestId: String
    let event: String  // "delta" | "done" | "error"
    let delta: String?
    let text: String?  // Final text on "done"
    let error: RPCError?
    
    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case event
        case delta
        case text
        case error
    }
}
