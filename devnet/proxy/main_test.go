package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"strings"
	"testing"
)

func TestDeny(t *testing.T) {
	cases := []struct {
		name    string
		body    string
		refused bool
	}{
		{"public call", `{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}`, false},
		{"raw tx", `{"jsonrpc":"2.0","id":1,"method":"eth_sendRawTransaction","params":["0x"]}`, false},
		{"public batch", `[{"id":1,"method":"eth_blockNumber"},{"id":2,"method":"eth_call","params":[]}]`, false},
		{"cheatcode", `{"id":1,"method":"anvil_setBalance","params":[]}`, true},
		{"evm cheatcode", `{"id":1,"method":"evm_increaseTime","params":[1]}`, true},
		{"unlocked send", `{"id":1,"method":"eth_sendTransaction","params":[{}]}`, true},
		{"tracing", `{"id":1,"method":"debug_traceTransaction","params":[]}`, true},
		{"batch hiding a cheatcode", `[{"id":1,"method":"eth_chainId"},{"id":2,"method":"anvil_reset"}]`, true},
		{"case-variant key", `{"id":1,"method":"anvil_setCode","Method":"eth_call"}`, true},
		{"duplicate method key", `{"id":1,"method":"anvil_setCode","method":"eth_call"}`, true},
		{"escaped method", `{"id":1,"method":"anvil\u005fsetCode"}`, true},
		{"escaped key", `{"id":1,"\u006dethod":"anvil_setCode"}`, true},
		{"escaped key hiding a cheatcode", `{"id":1,"\u006dethod":"anvil_setCode","method":"eth_call"}`, true},
		{"escaped public method", `{"id":1,"method":"eth\u005fchainId"}`, false},
		{"non-string method", `{"id":1,"method":["eth_call"]}`, true},
		{"missing method", `{"id":1}`, true},
		{"trailing value", `{"id":1,"method":"eth_call"} {"id":2,"method":"anvil_reset"}`, true},
		{"malformed", `{"id":1,"method":`, true},
		{"empty batch", `[]`, true},
		{"batch of non-objects", `["eth_call"]`, true},
		{"batch at the cap", batchOf(maxBatch, "eth_chainId"), false},
		{"batch over the cap", batchOf(maxBatch+1, "eth_chainId"), true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			resp, _ := deny([]byte(c.body))
			if got := resp != nil; got != c.refused {
				t.Fatalf("refused = %v, want %v", got, c.refused)
			}
		})
	}
}

func batchOf(n int, method string) string {
	calls := make([]string, n)
	for i := range calls {
		calls[i] = fmt.Sprintf(`{"id":%d,"method":%q}`, i, method)
	}
	return "[" + strings.Join(calls, ",") + "]"
}

// A refused batch answers each call with its own method only, so the response grows linearly
// with the request instead of echoing every refused name into every error.
func TestDenyResponseIsLinear(t *testing.T) {
	long := "anvil_" + strings.Repeat("x", 10_000)
	body := batchOf(maxBatch, long)
	resp, refused := deny([]byte(body))
	if resp == nil || len(refused) != maxBatch {
		t.Fatalf("refused %d calls, want %d", len(refused), maxBatch)
	}
	out, _ := json.Marshal(resp)
	if len(out) > 300*maxBatch {
		t.Fatalf("response is %d bytes for a %d-byte request", len(out), len(body))
	}
	var calls []rpcResponse
	if err := json.Unmarshal(out, &calls); err != nil || len(calls) != maxBatch {
		t.Fatalf("decode: %v, %d calls", err, len(calls))
	}
	if strings.Contains(calls[0].Error.Message, strings.Repeat("x", maxMethodEcho+1)) {
		t.Fatalf("method name not truncated: %s", calls[0].Error.Message)
	}

	resp, _ = deny([]byte(`[{"id":1,"method":"eth_chainId"},{"id":2,"method":"anvil_reset"}]`))
	mixed := resp.([]rpcResponse)
	if strings.Contains(mixed[0].Error.Message, "anvil_reset") || !strings.Contains(mixed[1].Error.Message, `"anvil_reset"`) {
		t.Fatalf("per-call messages: %q, %q", mixed[0].Error.Message, mixed[1].Error.Message)
	}

	resp, _ = deny([]byte(batchOf(maxBatch+1, "eth_chainId")))
	if r, ok := resp.(rpcResponse); !ok || r.Error.Code != -32600 {
		t.Fatalf("oversized batch: %+v", resp)
	}
}

func TestServeHTTP(t *testing.T) {
	var forwarded []string
	anvil := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		forwarded = append(forwarded, r.Method+" "+r.URL.Path+" "+string(body))
		w.Header().Set("Access-Control-Allow-Origin", "*")
		_, _ = io.WriteString(w, `{"jsonrpc":"2.0","id":1,"result":"0x2707"}`)
	}))
	defer anvil.Close()
	target, _ := url.Parse(anvil.URL)
	token := "0123456789abcdef0123456789abcdef"
	h := &handler{anvil: httputil.NewSingleHostReverseProxy(target), adminToken: token}

	do := func(method, path, body string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(method, path, strings.NewReader(body)))
		return rec
	}
	cheat := `{"jsonrpc":"2.0","id":7,"method":"anvil_setBalance","params":[]}`

	forwarded = nil
	if rec := do("POST", "/", `{"jsonrpc":"2.0","id":1,"method":"eth_chainId"}`); rec.Code != 200 || len(forwarded) != 1 {
		t.Fatalf("public call: code %d, forwarded %v", rec.Code, forwarded)
	}

	forwarded = nil
	rec := do("POST", "/", cheat)
	if len(forwarded) != 0 || !strings.Contains(rec.Body.String(), `"id":7`) || !strings.Contains(rec.Body.String(), "-32601") {
		t.Fatalf("cheatcode on public door: forwarded %v, body %s", forwarded, rec.Body.String())
	}

	forwarded = nil
	if rec := do("POST", "/admin/"+token, cheat); rec.Code != 200 || len(forwarded) != 1 || !strings.HasPrefix(forwarded[0], "POST / ") {
		t.Fatalf("admin door: code %d, forwarded %v", rec.Code, forwarded)
	}

	forwarded = nil
	for _, path := range []string{"/admin/wrong-token-wrong-token-wrong", "/admin/", "/admin", "/x"} {
		if rec := do("POST", path, cheat); rec.Code != 404 {
			t.Fatalf("%s: code %d, want 404", path, rec.Code)
		}
	}
	if len(forwarded) != 0 {
		t.Fatalf("unknown paths forwarded %v", forwarded)
	}

	if rec := do("GET", "/", ""); rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET: code %d", rec.Code)
	}

	forwarded = nil
	if rec := do("OPTIONS", "/", ""); rec.Code != 200 || len(forwarded) != 1 {
		t.Fatalf("preflight: code %d, forwarded %v", rec.Code, forwarded)
	}

	closed := &handler{anvil: h.anvil}
	rec = httptest.NewRecorder()
	closed.ServeHTTP(rec, httptest.NewRequest("POST", "/admin/", strings.NewReader(cheat)))
	if rec.Code != 404 {
		t.Fatalf("admin door without a token: code %d", rec.Code)
	}
}
