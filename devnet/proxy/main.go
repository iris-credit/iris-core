// Command devnet-proxy is the devnet's public door. It forwards standard JSON-RPC to anvil and
// refuses everything else (cheatcodes, unlocked-account signing, tracing), except on
// /admin/<ADMIN_TOKEN>, which passes every method through. Project-internal consumers bypass it and
// talk to anvil's own port on the private network.
package main

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"time"
)

const maxBody = 5 << 20

// Exact names only: a prefix rule would also admit eth_sendTransaction, which anvil runs as an
// unauthenticated arbitrary-sender write under --auto-impersonate.
var publicMethods = setOf(
	"web3_clientVersion", "web3_sha3", "net_version", "net_listening", "net_peerCount",
	"eth_chainId", "eth_blockNumber", "eth_syncing", "eth_accounts",
	"eth_gasPrice", "eth_maxPriorityFeePerGas", "eth_feeHistory", "eth_blobBaseFee",
	"eth_getBalance", "eth_getCode", "eth_getStorageAt", "eth_getTransactionCount", "eth_getProof",
	"eth_call", "eth_estimateGas", "eth_createAccessList", "eth_simulateV1",
	"eth_getBlockByNumber", "eth_getBlockByHash", "eth_getBlockReceipts",
	"eth_getBlockTransactionCountByNumber", "eth_getBlockTransactionCountByHash",
	"eth_getUncleCountByBlockNumber", "eth_getUncleCountByBlockHash",
	"eth_getUncleByBlockNumberAndIndex", "eth_getUncleByBlockHashAndIndex",
	"eth_getTransactionByHash", "eth_getTransactionByBlockNumberAndIndex",
	"eth_getTransactionByBlockHashAndIndex", "eth_getTransactionReceipt",
	"eth_getLogs", "eth_newFilter", "eth_newBlockFilter", "eth_newPendingTransactionFilter",
	"eth_getFilterChanges", "eth_getFilterLogs", "eth_uninstallFilter",
	"eth_sendRawTransaction",
)

func setOf(names ...string) map[string]bool {
	m := make(map[string]bool, len(names))
	for _, n := range names {
		m[n] = true
	}
	return m
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Error   rpcError        `json:"error"`
}

// request is one JSON-RPC call as anvil will read it: the exact, case-sensitive "method" key.
type request struct {
	id     json.RawMessage
	method string
}

var errMalformed = errors.New("malformed JSON-RPC request")

// parseRequest walks the object's keys itself rather than unmarshalling into a struct:
// encoding/json matches field names case-insensitively, so {"method":"anvil_setCode","Method":"eth_call"}
// would read as eth_call here while anvil runs anvil_setCode. A repeated "method" key is refused.
func parseRequest(raw json.RawMessage) (request, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	if tok, err := dec.Token(); err != nil || tok != json.Delim('{') {
		return request{}, errMalformed
	}
	req := request{id: json.RawMessage("null")}
	seenMethod := false
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return request{}, errMalformed
		}
		key, _ := tok.(string)
		var value json.RawMessage
		if err := dec.Decode(&value); err != nil {
			return request{}, errMalformed
		}
		switch key {
		case "method":
			if seenMethod || json.Unmarshal(value, &req.method) != nil {
				return request{}, errMalformed
			}
			seenMethod = true
		case "id":
			req.id = value
		}
	}
	if !seenMethod {
		return request{}, errMalformed
	}
	return req, nil
}

// parseBody returns the calls in a single or batch request, and whether it was a batch.
func parseBody(body []byte) ([]request, bool, error) {
	trimmed := bytes.TrimSpace(body)
	if !json.Valid(trimmed) { // also rejects a second value trailing the first
		return nil, false, errMalformed
	}
	if trimmed[0] == '[' {
		var items []json.RawMessage
		if err := json.Unmarshal(trimmed, &items); err != nil || len(items) == 0 {
			return nil, true, errMalformed
		}
		reqs := make([]request, len(items))
		for i, item := range items {
			req, err := parseRequest(item)
			if err != nil {
				return nil, true, err
			}
			reqs[i] = req
		}
		return reqs, true, nil
	}
	req, err := parseRequest(trimmed)
	if err != nil {
		return nil, false, err
	}
	return []request{req}, false, nil
}

// deny returns the response to send instead of forwarding, or nil when every call is public.
// A batch with any refused call is refused whole, one error per call.
func deny(body []byte) (any, []string) {
	reqs, batch, err := parseBody(body)
	if err != nil {
		return rpcResponse{"2.0", json.RawMessage("null"), rpcError{-32700, err.Error()}}, []string{"<malformed>"}
	}
	var refused []string
	for _, r := range reqs {
		if !publicMethods[r.method] {
			refused = append(refused, r.method)
		}
	}
	if len(refused) == 0 {
		return nil, nil
	}
	msg := "method not available on the public devnet RPC: " + strings.Join(refused, ", ")
	out := make([]rpcResponse, len(reqs))
	for i, r := range reqs {
		out[i] = rpcResponse{"2.0", r.id, rpcError{-32601, msg}}
	}
	if batch {
		return out, refused
	}
	return out[0], refused
}

type handler struct {
	anvil      *httputil.ReverseProxy
	adminToken string
}

// route reports whether the path is served and whether it is the admin door.
func (h *handler) route(path string) (admin, ok bool) {
	if path == "/" || path == "" {
		return false, true
	}
	token, found := strings.CutPrefix(path, "/admin/")
	if !found || h.adminToken == "" {
		return false, false
	}
	return true, subtle.ConstantTimeCompare([]byte(token), []byte(h.adminToken)) == 1
}

func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	admin, ok := h.route(r.URL.Path)
	if !ok {
		http.NotFound(w, r)
		return
	}
	r.URL.Path, r.URL.RawPath = "/", "" // anvil serves JSON-RPC on "/"; the token never reaches it
	if r.Method == http.MethodOptions {
		h.anvil.ServeHTTP(w, r) // CORS preflight, answered by anvil
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "JSON-RPC over HTTP POST only", http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
	if err != nil {
		http.Error(w, "request body too large", http.StatusRequestEntityTooLarge)
		return
	}
	if !admin {
		if resp, refused := deny(body); resp != nil {
			log.Printf("refused %s from %s", strings.Join(refused, ","), clientIP(r))
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(resp)
			return
		}
	}
	r.Body = io.NopCloser(bytes.NewReader(body))
	r.ContentLength = int64(len(body))
	h.anvil.ServeHTTP(w, r)
}

func clientIP(r *http.Request) string {
	if ip := r.Header.Get("Cf-Connecting-Ip"); ip != "" {
		return ip
	}
	return r.RemoteAddr
}

func main() {
	target, err := url.Parse(envOr("ANVIL_URL", "http://127.0.0.1:8545"))
	if err != nil {
		log.Fatalf("ANVIL_URL: %v", err)
	}
	token := os.Getenv("ADMIN_TOKEN")
	if len(token) < 24 {
		log.Printf("ADMIN_TOKEN unset or shorter than 24 characters: the admin door is closed")
		token = ""
	}
	anvil := httputil.NewSingleHostReverseProxy(target)
	anvil.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		if errors.Is(err, context.Canceled) {
			return // the client hung up; nothing to answer
		}
		log.Printf("anvil unreachable: %v", err)
		w.WriteHeader(http.StatusBadGateway)
	}
	srv := &http.Server{
		Addr:              ":" + envOr("PROXY_PORT", "8080"),
		Handler:           &handler{anvil: anvil, adminToken: token},
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("devnet-proxy on %s -> %s", srv.Addr, target)
	log.Fatal(srv.ListenAndServe())
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
