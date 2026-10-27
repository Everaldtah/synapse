import XCTest
@testable import SynapseKit

final class APIProviderTests: XCTestCase {
    func testCatalog() {
        let ids = APIProviderCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "unique ids")
        for p in APIProviderCatalog.all {
            XCTAssertTrue(p.baseURL.hasPrefix("https://"), p.id)
            XCTAssertFalse(p.baseURL.hasSuffix("/"), p.id)
            XCTAssertFalse(p.baseURL.hasSuffix("/chat/completions"), p.id)
            XCTAssertTrue(p.isFree == APIProviderCatalog.free.contains(p), p.id)
            if !p.listsModels { XCTAssertFalse(p.models.isEmpty, "\(p.id) has no model list, so it needs built-in models") }
        }
        XCTAssertNotNil(APIProviderCatalog.provider("nvidia"))
        XCTAssertNotNil(APIProviderCatalog.provider("xai"))
        XCTAssertFalse(APIProviderCatalog.provider("ovh")!.needsKey)
        XCTAssertTrue(APIProviderCatalog.provider("groq")!.needsKey)
        XCTAssertEqual(OpenAICompat.baseURL("https://x/accounts/{account_id}/ai/v1/", values: ["account_id": " abc "]), "https://x/accounts/abc/ai/v1")
        XCTAssertEqual(APIModelInfo("nvidia/nemotron-3-ultra-550b-a55b:free").shortName, "nemotron-3-ultra-550b-a55b")
        XCTAssertTrue(APIProviderCatalog.custom(name: "LM Studio", baseURL: "http://pc:1234/v1").custom)
    }

    func testBody() throws {
        let req = AIRequest(system: "Be brief.", messages: [AIMessage(role: .user, content: "Hi"), AIMessage(role: .assistant, content: "Hello"),
                                                            AIMessage(role: .user, content: "What is this?")])
        let body = OpenAICompat.body(req, model: "m", images: ["QUJD"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["content"] as? String, "Hi")
        let parts = try XCTUnwrap(messages[3]["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual((parts[1]["image_url"] as? [String: Any])?["url"] as? String, "data:image/jpeg;base64,QUJD")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    func testStreamChunks() {
        XCTAssertNil(OpenAICompat.chunk(line: ": keep-alive"))
        XCTAssertNil(OpenAICompat.chunk(line: ""))
        XCTAssertEqual(OpenAICompat.chunk(line: "data: [DONE]")?.done, true)
        XCTAssertEqual(OpenAICompat.chunk(line: #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#)?.text, "Hel")
        let r = OpenAICompat.chunk(line: #"data: {"choices":[{"delta":{"reasoning_content":"think","content":null},"finish_reason":null}]}"#)
        XCTAssertEqual(r?.reasoning, "think")
        XCTAssertEqual(r?.text, "")
        XCTAssertEqual(OpenAICompat.chunk(line: #"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#)?.finishReason, "length")
        XCTAssertEqual(OpenAICompat.chunk(line: #"data: {"error":{"message":"Rate limit"}}"#)?.error, "Rate limit")
        XCTAssertEqual(OpenAICompat.text(fromResponse: Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8)), "ok")
    }

    func testNativeToolCalls() {
        XCTAssertEqual(NativeToolCalls.markup(name: "create_page", arguments: ##"{"title":"Bob's \"notes\"","markdown":"# Hi","depth":2,"show":true}"##),
                       ##"<tool name="create_page" depth="2" show="true" title="Bob's 'notes'"># Hi</tool>"##)
        XCTAssertEqual(NativeToolCalls.markup(name: "functions.web_search", arguments: #"{"q":"krebs"}"#), #"<tool name="web_search">krebs</tool>"#)
        XCTAssertEqual(NativeToolCalls.markup(name: "list_pages", arguments: "{}"), #"<tool name="list_pages"></tool>"#)

        // Streamed deltas: the name once, the arguments in pieces.
        var acc = NativeToolCalls.Accumulator()
        for line in [#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"read_page","arguments":"{\"in"}}]}}]}"#,
                     #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"put\":\"Home\"}"}}]}}]}"#] {
            acc.add(OpenAICompat.chunk(line: line)?.toolCalls ?? [])
        }
        XCTAssertEqual(acc.markup, #"<tool name="read_page">Home</tool>"#)
        let whole = #"{"choices":[{"message":{"content":null,"tool_calls":[{"function":{"name":"list_pages","arguments":"{}"}}]}}]}"#
        XCTAssertEqual(OpenAICompat.text(fromResponse: Data(whole.utf8)), #"<tool name="list_pages"></tool>"#)

        // gpt-oss harmony text.
        let harmony = """
        <|start|>assistant<|channel|>commentary to=tool{
        "name": "create_page",
        "title": "Photosynthesis",
        "icon": "🌿"
        }---
        # Photosynthesis
        Links [[Calvin cycle]].
        <|call|>
        """
        let calls = Agent.parseCalls(harmony, known: ["create_page"])
        XCTAssertEqual(calls.first?.name, "create_page")
        XCTAssertEqual(calls.first?.attributes["title"], "Photosynthesis")
        XCTAssertEqual(calls.first?.input, "# Photosynthesis\nLinks [[Calvin cycle]].")
        let fn = #"<|channel|>commentary to=functions.web_search <|constrain|>json<|message|>{"query":"tides"}<|call|>"#
        XCTAssertEqual(Agent.parseCalls(fn, known: ["web_search"]).first?.input, "tides")
        XCTAssertEqual(Agent.cleanAnswer("<|channel|>analysis<|message|>thinking<|end|><|start|>assistant<|channel|>final<|message|>The answer."), "The answer.")
    }

    func testModelsList() {
        let json = #"{"data":[{"id":"b-model:free","context_length":8192},{"id":"a-model"},{"id":"text-embedding-3"},{"id":"c:free"},{"id":"whisper-large-v3"}]}"#
        XCTAssertEqual(OpenAICompat.models(from: Data(json.utf8)).map(\.id), ["a-model", "b-model:free", "c:free"])
        XCTAssertEqual(OpenAICompat.models(from: Data(json.utf8), freeSuffix: ":free").map(\.id), ["b-model:free", "c:free"])
        XCTAssertEqual(OpenAICompat.models(from: Data(json.utf8)).first { $0.id == "b-model:free" }?.contextTokens, 8192)
        XCTAssertEqual(OpenAICompat.models(from: Data(#"{"models":[{"name":"models/gemini-3.8-flash"}]}"#.utf8)).map(\.id), ["gemini-3.8-flash"])
        XCTAssertTrue(OpenAICompat.errorMessage(code: 429, body: #"{"error":{"message":"slow down"}}"#, provider: "Groq").contains("slow down"))
        XCTAssertTrue(OpenAICompat.errorMessage(code: 401, body: "", provider: "Groq").contains("rejected the API key"))
    }
}
