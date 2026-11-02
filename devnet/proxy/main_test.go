package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// The escapes are assembled at run time: typed literally, an editing tool once decoded them and
// these cases silently tested the plain method name.
var (
	bs            = string(rune(92)) // a backslash
	escapedMethod = `{"id":1,"method":"anvil` + bs + `u005fsetCode"}`
	escapedKey    = `{"id":1,"meth` + bs + `u006fd":"anvil_setCode"}`
)

func TestEscapes(t *testing.T) {
	for _, body := range []string{escapedMethod, escapedKey} {
		if !strings.Contains(body, bs) {
			t.Fatalf("%s holds no backslash, so it tests no escape", body)
		}
		req, err := parseRequest(json.RawMessage(body))
		if err != nil || req.method != "anvil_setCode" {
			t.Fatalf("%s: method %q, err %v; want anvil_setCode", body, req.method, err)
		}
	}
}

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
		{"escaped method", escapedMethod, true},
		{"escaped key", escapedKey, true},
		{"escaped duplicate key", `{"id":1,"method":"eth_call","meth` + bs + `u006fd":"anvil_setCode"}`, true},
		{"escaped key before a plain duplicate", `{"id":1,"meth` + bs + `u006fd":"anvil_setCode","method":"eth_call"}`, true},
		{"escaped public method", `{"id":1,"method":"eth` + bs + `u005fchainId"}`, false},
		{"subscribe", `{"id":1,"method":"eth_subscribe","params":["newHeads"]}`, false},
		{"non-string method", `{"id":1,"method":["eth_call"]}`, true},
		{"missing method", `{"id":1}`, true},
		{"trailing value", `{"id":1,"method":"eth_call"} {"id":2,"method":"anvil_reset"}`, true},
		{"malformed", `{"id":1,"method":`, true},
		{"empty batch", `[]`, true},
		{"batch of non-objects", `["eth_call"]`, true},
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

// A refused batch's answer must grow with the request, not with its square.
func TestRefusedBatchSize(t *testing.T) {
	h := &handler{}
	batch := func(n int, call string) string {
		return "[" + strings.TrimSuffix(strings.Repeat(call+",", n), ",") + "]"
	}
	for _, c := range []struct {
		body  string
		ratio int
	}{
		{batch(maxBatch, `{"jsonrpc":"2.0","id":1,"method":"anvil_setBalance","params":[]}`), 3},
		{batch(maxBatch, `{"method":"x"}`), 8}, // the most error bytes per request byte
		{batch(maxBatch, `{"method":"`+strings.Repeat("a", 4096)+`"}`), 1},
	} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("POST", "/", strings.NewReader(c.body)))
		var out []rpcResponse
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil || len(out) != maxBatch {
			t.Fatalf("want %d errors, got %d (%v)", maxBatch, len(out), err)
		}
		if got := rec.Body.Len(); got > c.ratio*len(c.body) {
			t.Fatalf("%d-byte request got a %d-byte answer, over %dx", len(c.body), got, c.ratio)
		}
	}

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("POST", "/", strings.NewReader(batch(maxBatch+1, `{"id":1,"method":"eth_chainId"}`))))
	var one rpcResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &one); err != nil || one.Error.Code != -32600 {
		t.Fatalf("oversize batch: want one -32600 error, got %s", rec.Body.String())
	}
}

func TestWebSocket(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	var mu sync.Mutex
	var forwarded []string
	upstreamClosed := make(chan websocket.StatusCode, 4)
	anvil := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		for {
			_, msg, err := c.Read(ctx)
			if err != nil {
				upstreamClosed <- websocket.CloseStatus(err)
				return
			}
			mu.Lock()
			forwarded = append(forwarded, string(msg))
			mu.Unlock()
			_ = c.Write(ctx, websocket.MessageText, []byte(`{"jsonrpc":"2.0","id":1,"result":"0x1"}`))
		}
	}))
	defer anvil.Close()
	token := "0123456789abcdef0123456789abcdef"
	proxy := httptest.NewServer(&handler{anvilWS: "ws" + strings.TrimPrefix(anvil.URL, "http"), adminToken: token})
	defer proxy.Close()
	base := "ws" + strings.TrimPrefix(proxy.URL, "http")

	dial := func(path string) *websocket.Conn {
		c, _, err := websocket.Dial(ctx, base+path, nil)
		if err != nil {
			t.Fatalf("dial %s: %v", path, err)
		}
		return c
	}
	call := func(c *websocket.Conn, typ websocket.MessageType, req string) string {
		if err := c.Write(ctx, typ, []byte(req)); err != nil {
			t.Fatalf("write: %v", err)
		}
		_, resp, err := c.Read(ctx)
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		return string(resp)
	}
	takeForwarded := func() []string {
		mu.Lock()
		defer mu.Unlock()
		f := forwarded
		forwarded = nil
		return f
	}
	sub := `{"jsonrpc":"2.0","id":1,"method":"eth_subscribe","params":["newHeads"]}`
	cheat := `{"jsonrpc":"2.0","id":7,"method":"anvil_setBalance","params":[]}`

	pub := dial("/")
	if resp := call(pub, websocket.MessageText, sub); !strings.Contains(resp, `"result"`) {
		t.Fatalf("public subscribe: %s", resp)
	}
	for _, typ := range []websocket.MessageType{websocket.MessageText, websocket.MessageBinary} {
		if resp := call(pub, typ, cheat); !strings.Contains(resp, "-32601") || !strings.Contains(resp, `"id":7`) {
			t.Fatalf("public cheatcode (%v): %s", typ, resp)
		}
	}
	_ = pub.Close(websocket.StatusNormalClosure, "")
	if s := <-upstreamClosed; s != websocket.StatusNormalClosure {
		t.Fatalf("client's close reached anvil as %v", s)
	}
	if f := takeForwarded(); len(f) != 1 || f[0] != sub {
		t.Fatalf("public door forwarded %v, want only the subscribe", f)
	}

	adm := dial("/admin/" + token)
	if resp := call(adm, websocket.MessageText, cheat); !strings.Contains(resp, `"result"`) {
		t.Fatalf("admin cheatcode: %s", resp)
	}
	_ = adm.Close(websocket.StatusNormalClosure, "")
	<-upstreamClosed
	if f := takeForwarded(); len(f) != 1 || f[0] != cheat {
		t.Fatalf("admin door forwarded %v", f)
	}

	_, resp, err := websocket.Dial(ctx, base+"/admin/wrong-token-wrong-token-wrong", nil)
	if err == nil || resp == nil || resp.StatusCode != 404 {
		t.Fatalf("wrong token: err %v, resp %v", err, resp)
	}
	if f := takeForwarded(); len(f) != 0 {
		t.Fatalf("wrong token forwarded %v", f)
	}
}
