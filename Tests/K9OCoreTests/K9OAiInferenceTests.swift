import XCTest
@testable import K9OCore

private final class Capture: @unchecked Sendable {
    var requests: [URLRequest] = []
    var bodies: [Data] = []
}

private func stub(
    _ cap: Capture, status: Int = 200, body: [String: Any]? = nil, raw: Data? = nil, fail: Error? = nil
) -> K9OTransport {
    return { req in
        cap.requests.append(req)
        cap.bodies.append(req.httpBody ?? Data())
        if let fail { throw fail }
        let data = raw ?? (try! JSONSerialization.data(withJSONObject: body ?? [
            "data": ["modelId": "llama-3.1-8b", "content": "Hello there", "finishReason": "stop",
                      "usage": ["promptTokens": 3, "completionTokens": 2, "totalTokens": 5], "usageType": "chat"],
            "meta": [String: Any](),
        ]))
        let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        return (data, resp)
    }
}

private func client(_ t: @escaping K9OTransport, slug: String? = "member-portal") -> K9OCoreClient {
    K9OCoreClient(baseURL: URL(string: "https://acme.api.k9o.io")!, projectSlug: slug,
                  accessToken: "tok_abc", transport: t)
}

private func json(_ d: Data) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: d) as! [String: Any]
}

final class K9OAiInferenceTests: XCTestCase {
    func testPostsFlatBodyToGeneratePathAndParsesResponse() async throws {
        let cap = Capture()
        let r = try await client(stub(cap)).ai.generate(
            "hi", model: "llama-3.1-8b", maxTokens: 10, temperature: 0.2)
        XCTAssertEqual(cap.requests.count, 1)
        XCTAssertEqual(cap.requests[0].httpMethod, "POST")
        XCTAssertEqual(cap.requests[0].url?.absoluteString,
                       "https://acme.api.k9o.io/@member-portal/ai/generate")
        XCTAssertEqual(cap.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tok_abc")
        let b = json(cap.bodies[0])
        XCTAssertEqual(b["prompt"] as? String, "hi")
        XCTAssertEqual(b["maxTokens"] as? Int, 10)
        XCTAssertEqual(b["temperature"] as? Double, 0.2)
        XCTAssertEqual(b["model"] as? String, "llama-3.1-8b")
        XCTAssertEqual(b.count, 4)
        XCTAssertEqual(r.data.modelId, "llama-3.1-8b")
        XCTAssertEqual(r.data.content, "Hello there")
        XCTAssertEqual(r.data.finishReason, "stop")
        XCTAssertEqual(r.data.usage, K9OInferenceUsage(promptTokens: 3, completionTokens: 2, totalTokens: 5))
    }

    func testOptionalParamsOmitted() async throws {
        let cap = Capture()
        _ = try await client(stub(cap)).ai.generate("p")
        let b = json(cap.bodies[0])
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b["prompt"] as? String, "p")
    }

    func testMissingSlugRefusedWithoutRequest() async {
        let cap = Capture()
        do {
            _ = try await client(stub(cap), slug: nil).ai.generate("p")
            XCTFail("expected throw")
        } catch let e as K9OError {
            XCTAssertEqual(e.code, "K9O_MISSING_PROJECT_CONTEXT")
        } catch { XCTFail("wrong error \(error)") }
        XCTAssertEqual(cap.requests.count, 0)
    }

    func testNotImplementedSurfacesAsKErrorWithoutPrompt() async {
        let cap = Capture()
        let secret = "the-secret-prompt"
        let body: [String: Any] = [
            "code": "K9O_NOT_IMPLEMENTED", "message": "external provider not built",
            "context": [String: Any](), "recommendation": NSNull(),
        ]
        do {
            _ = try await client(stub(cap, status: 501, body: body)).ai.generate(secret, model: "gpt-4o")
            XCTFail("expected throw")
        } catch let e as K9OError {
            XCTAssertEqual(e.code, "K9O_NOT_IMPLEMENTED")
            XCTAssertEqual(e.status, 501)
            XCTAssertFalse(e.description.contains(secret))
        } catch { XCTFail("wrong error \(error)") }
    }

    func testNoDefaultModelSurfacesAs400KError() async {
        let cap = Capture()
        let body: [String: Any] = [
            "code": "K9O_INVALID_FIELD_VALUE", "message": "Name a model: this org has no default LLM",
            "context": ["field": "model"], "recommendation": NSNull(),
        ]
        do {
            _ = try await client(stub(cap, status: 400, body: body)).ai.generate("hi")
            XCTFail("expected throw")
        } catch let e as K9OError {
            XCTAssertEqual(e.code, "K9O_INVALID_FIELD_VALUE")
            XCTAssertEqual(e.status, 400)
        } catch { XCTFail("wrong error \(error)") }
        XCTAssertNil(json(cap.bodies[0])["model"])
    }
}
