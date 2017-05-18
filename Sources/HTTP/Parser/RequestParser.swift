import CHTTPParser
import Core
import Foundation
import Venice

public typealias RequestParserError = http_errno

extension RequestParserError : Error, CustomStringConvertible {
    public var description: String {
        return String(cString: http_errno_description(self))
    }
}

extension Request.Method {
    internal init(code: http_method) {
        switch code {
        case HTTP_DELETE: self = .delete
        case HTTP_GET: self = .get
        case HTTP_HEAD: self = .head
        case HTTP_POST: self = .post
        case HTTP_PUT: self = .put
        case HTTP_CONNECT: self = .connect
        case HTTP_OPTIONS: self = .options
        case HTTP_TRACE: self = .trace
        case HTTP_COPY: self = .other("COPY")
        case HTTP_LOCK: self = .other("LOCK")
        case HTTP_MKCOL: self = .other("MKCOL")
        case HTTP_MOVE: self = .other("MOVE")
        case HTTP_PROPFIND: self = .other("PROPFIND")
        case HTTP_PROPPATCH: self = .other("PROPPATCH")
        case HTTP_SEARCH: self = .other("SEARCH")
        case HTTP_UNLOCK: self = .other("UNLOCK")
        case HTTP_BIND: self = .other("BIND")
        case HTTP_REBIND: self = .other("REBIND")
        case HTTP_UNBIND: self = .other("UNBIND")
        case HTTP_ACL: self = .other("ACL")
        case HTTP_REPORT: self = .other("REPORT")
        case HTTP_MKACTIVITY: self = .other("MKACTIVITY")
        case HTTP_CHECKOUT: self = .other("CHECKOUT")
        case HTTP_MERGE: self = .other("MERGE")
        case HTTP_MSEARCH: self = .other("M-SEARCH")
        case HTTP_NOTIFY: self = .other("NOTIFY")
        case HTTP_SUBSCRIBE: self = .other("SUBSCRIBE")
        case HTTP_UNSUBSCRIBE: self = .other("UNSUBSCRIBE")
        case HTTP_PATCH: self = .patch
        case HTTP_PURGE: self = .other("PURGE")
        case HTTP_MKCALENDAR: self = .other("MKCALENDAR")
        case HTTP_LINK: self = .other("LINK")
        case HTTP_UNLINK: self = .other("UNLINK")
        default: self = .other("UNKNOWN")
        }
    }
}

extension URI {
    init?(buffer: UnsafeRawBufferPointer, isConnect: Bool) {
        let uri = parse_uri(
            buffer.baseAddress?.assumingMemoryBound(to: Int8.self),
            buffer.count,
            isConnect ? 1 : 0
        )
        
        if uri.error == 1 {
            return nil
        }
        
        let scheme: String?
        let userInfo: UserInfo?
        let host: String?
        let port: Int?
        let path: String?
        let query:  String?
        let fragment: String?
        
        if uri.field_set & 1 != 0 {
            scheme = URI.substring(buffer: buffer, start: uri.scheme_start, end: uri.scheme_end)
        } else {
            scheme = nil
        }
        
        if uri.field_set & 2 != 0 {
            host = URI.substring(buffer: buffer, start: uri.host_start, end: uri.host_end)
        } else {
            host = nil
        }
        
        if uri.field_set & 4 != 0 {
            port = Int(uri.port)
        } else {
            port = nil
        }
        
        if uri.field_set & 8 != 0 {
            path = URI.substring(buffer: buffer, start: uri.path_start, end: uri.path_end)
        } else {
            path = nil
        }
        
        if uri.field_set & 16 != 0 {
            query = URI.substring(buffer: buffer, start: uri.query_start, end: uri.query_end)
        } else {
            query = nil
        }
        
        if uri.field_set & 32 != 0 {
            fragment = URI.substring(buffer: buffer, start: uri.fragment_start, end: uri.fragment_end)
        } else {
            fragment = nil
        }
        
        if uri.field_set & 64 != 0 {
            let userInfoString = URI.substring(
                buffer: buffer,
                start: uri.user_info_start,
                end: uri.user_info_end
            )
            
            userInfo = URI.userInfo(userInfoString)
        } else {
            userInfo = nil
        }
        
        self.init(
            scheme: scheme,
            userInfo: userInfo,
            host: host,
            port: port,
            path: path,
            query: query,
            fragment: fragment
        )
    }
    
    @inline(__always)
    private static func substring(buffer: UnsafeRawBufferPointer, start: UInt16, end: UInt16) -> String {
        let bytes = [UInt8](buffer[Int(start) ..< Int(end)]) + [0]
        
        return bytes.withUnsafeBufferPointer { (pointer: UnsafeBufferPointer<UInt8>) -> String in
            return String(cString: pointer.baseAddress!)
        }
    }
    
    @inline(__always)
    private static func userInfo(_ string: String?) -> URI.UserInfo? {
        guard let string = string else {
            return nil
        }
        
        let components = string.components(separatedBy: ":")
        
        if components.count == 2 {
            return URI.UserInfo(
                username: components[0],
                password: components[1]
            )
        }
        
        return nil
    }
}

public final class RequestParser {
    fileprivate enum State: Int {
        case ready = 1
        case messageBegin = 2
        case uri = 3
        case headerField = 5
        case headerValue = 6
        case headersComplete = 7
        case body = 8
        case messageComplete = 9
    }
    
    fileprivate class Context {
        var uri: URI?
        var headers: Headers = [:]
        
        weak var bodyStream: RequestBodyStream?
        
        var currentHeaderField: HeaderField?
        
        func addValueForCurrentHeaderField(_ value: String) {
            guard let key = currentHeaderField else {
                return
            }
            
            if let existing = headers[key] {
                headers[key] = existing + ", " + value
            } else {
                headers[key] = value
            }
        }
    }
    
    private let stream: ReadableStream
    private let bufferSize: Int
    private let buffer: UnsafeMutableRawBufferPointer
    
    private var parser: http_parser
    private var parserSettings: http_parser_settings
    
    private var state: State = .ready
    private var context = Context()
    private var bytes: [UInt8] = []
    
    private var requests: [Request] = []
    
    public init(stream: ReadableStream, bufferSize: Int = 2048) {
        self.stream = stream
        self.bufferSize = bufferSize
        self.buffer = UnsafeMutableRawBufferPointer.allocate(count: bufferSize)
        
        var parser = http_parser()
        
        http_parser_init(&parser, HTTP_REQUEST)
        
        
        var parserSettings = http_parser_settings()
        http_parser_settings_init(&parserSettings)
        
        parserSettings.on_message_begin = http_parser_on_message_begin
        parserSettings.on_url = http_parser_on_url
        parserSettings.on_header_field = http_parser_on_header_field
        parserSettings.on_header_value = http_parser_on_header_value
        parserSettings.on_headers_complete = http_parser_on_headers_complete
        parserSettings.on_body = http_parser_on_body
        parserSettings.on_message_complete = http_parser_on_message_complete
        
        self.parser = parser
        self.parserSettings = parserSettings
        
        self.parser.data = Unmanaged.passUnretained(self).toOpaque()
    }
    
    deinit {
        buffer.deallocate()
    }
    
    public func parse(deadline: Deadline) throws -> Request {
        while true {
            guard requests.isEmpty else {
                return requests.removeFirst()
            }
            
            try read(deadline: deadline)
        }
    }
    
    func read(deadline: Deadline) throws {
        let read = try stream.read(buffer, deadline: deadline)
        
        if read.isEmpty {
            try stream.close()
        }
        
        try parse(read)
    }
    
    private func parse(_ buffer: UnsafeRawBufferPointer) throws {
        let final = buffer.isEmpty
        let needsMessage: Bool
        
        switch state {
        case .ready, .messageComplete:
            needsMessage = false
        default:
            needsMessage = final
        }
        
        let processedCount: Int
        
        if final {
            processedCount = http_parser_execute(&parser, &parserSettings, nil, 0)
        } else {
            processedCount = http_parser_execute(
                &parser,
                &parserSettings,
                buffer.baseAddress?.assumingMemoryBound(to: Int8.self),
                buffer.count
            )
        }
        
        guard processedCount == buffer.count else {
            throw RequestParserError(parser.http_errno)
        }
        
        guard !requests.isEmpty || !needsMessage else {
            throw RequestParserError(HPE_INVALID_EOF_STATE.rawValue)
        }
    }
    
    fileprivate func process(state newState: State, data: UnsafeRawBufferPointer? = nil) -> Int32 {
        if state != newState {
            switch state {
            case .ready, .messageBegin, .body, .messageComplete:
                break
            case .uri:
                guard let uri = bytes.withUnsafeBytes({ buffer in
                    return URI(buffer: buffer, isConnect: parser.method == HTTP_CONNECT.rawValue)
                }) else {
                    return 1
                }
                
                context.uri = uri
            case .headerField:
                bytes.append(0)
                
                let string = bytes.withUnsafeBufferPointer { (pointer: UnsafeBufferPointer<UInt8>) -> String in
                    return String(cString: pointer.baseAddress!)
                }
                
                context.currentHeaderField = HeaderField(string)
            case .headerValue:
                bytes.append(0)
                
                let string = bytes.withUnsafeBufferPointer { (pointer: UnsafeBufferPointer<UInt8>) -> String in
                    return String(cString: pointer.baseAddress!)
                }
                
                context.addValueForCurrentHeaderField(string)
            case .headersComplete:
                context.currentHeaderField = nil
                
                guard let uri = context.uri else {
                    return 1
                }
                
                let bodyStream = RequestBodyStream(parser: self)
                
                let request = Request(
                    method: Request.Method(code: http_method(rawValue: parser.method)),
                    uri: uri,
                    headers: context.headers,
                    version: Version(major: Int(parser.http_major), minor: Int(parser.http_minor)),
                    body: .readable(bodyStream)
                )
                
                context.bodyStream = bodyStream
                requests.append(request)
            }
            
            bytes = []
            state = newState
            
            if state == .messageComplete {
                context.bodyStream?.complete = true
                context = Context()
            }
        }
        
        guard let data = data, !data.isEmpty else {
            return 0
        }
        
        switch state {
        case .body:
            context.bodyStream?.bodyBuffer = data
        default:
            bytes.append(contentsOf: data)
        }
        
        return 0
    }
}

private func http_parser_on_message_begin(pointer: UnsafeMutablePointer<http_parser>?) -> Int32 {
    let parser = Unmanaged<RequestParser>.fromOpaque(pointer!.pointee.data).takeUnretainedValue()
    return parser.process(state: .messageBegin)
}

private func http_parser_on_url(
    pointer: UnsafeMutablePointer<http_parser>?,
    data: UnsafePointer<Int8>?,
    length: Int
) -> Int32 {
    let parser = Unmanaged<RequestParser>.fromOpaque(pointer!.pointee.data).takeUnretainedValue()
    return parser.process(state: .uri, data: UnsafeRawBufferPointer(start: data, count: length))
}

private func http_parser_on_header_field(
    pointer: UnsafeMutablePointer<http_parser>?,
    data: UnsafePointer<Int8>?,
    length: Int
) -> Int32 {
    let parser = Unmanaged<RequestParser>.fromOpaque(pointer!.pointee.data).takeUnretainedValue()
    return parser.process(state: .headerField, data: UnsafeRawBufferPointer(start: data, count: length))
}

private func http_parser_on_header_value(
    pointer: UnsafeMutablePointer<http_parser>?,
    data: UnsafePointer<Int8>?,
    length: Int
) -> Int32 {
    let parser = Unmanaged<RequestParser>.fromOpaque(pointer!.pointee.data).takeUnretainedValue()
    return parser.process(state: .headerValue, data: UnsafeRawBufferPointer(start: data, count: length))
}

private func http_parser_on_headers_complete(pointer: UnsafeMutablePointer<http_parser>?) -> Int32 {
    let parser = Unmanaged<RequestParser>.fromOpaque(pointer!.pointee.data).takeUnretainedValue()
    return parser.process(state: .headersComplete)
}

private func http_parser_on_body(
    pointer: UnsafeMutablePointer<http_parser>?,
    data: UnsafePointer<Int8>?,
    length: Int
) -> Int32 {
    let parser = Unmanaged<RequestParser>.fromOpaque(pointer!.pointee.data).takeUnretainedValue()
    return parser.process(state: .body, data: UnsafeRawBufferPointer(start: data, count: length))
}

private func http_parser_on_message_complete(pointer: UnsafeMutablePointer<http_parser>?) -> Int32 {
    let parser = Unmanaged<RequestParser>.fromOpaque(pointer!.pointee.data).takeUnretainedValue()
    return parser.process(state: .messageComplete)
}