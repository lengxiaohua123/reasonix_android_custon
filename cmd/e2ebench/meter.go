package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"maps"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
)

// meter is the harness-neutral measuring point: a proxy every harness talks to
// instead of the provider, so nobody in a comparison reports their own token
// use. It is also where LongRun injects provider faults, because the request
// boundary is the only place both benchmarks can reach without a harness's
// cooperation.
type meter struct {
	upstream *url.URL
	client   *http.Client
	faults   map[int]int // 1-based request index -> status to return instead

	mu sync.Mutex
	meterUsage
}

// meterUsage is what the proxy observed. WithoutUsage is reported rather than
// folded into zero: a harness whose responses carry no usage block is
// unmeasured, and that is a finding, not a zero.
type meterUsage struct {
	Requests         int `json:"requests"`
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	CacheHitTokens   int `json:"cache_hit_tokens"`
	CacheMissTokens  int `json:"cache_miss_tokens"`
	Injected         int `json:"injected_faults,omitempty"`
	WithoutUsage     int `json:"responses_without_usage,omitempty"`
}

// parseFaultScript reads "3:429,7:500" — inject that status instead of
// forwarding the Nth request. Deterministic by index so a LongRun arm replays
// the same failures across harnesses.
func parseFaultScript(spec string) (map[int]int, error) {
	if strings.TrimSpace(spec) == "" {
		return nil, nil
	}
	out := map[int]int{}
	for field := range strings.SplitSeq(spec, ",") {
		idx, status, ok := strings.Cut(strings.TrimSpace(field), ":")
		if !ok {
			return nil, fmt.Errorf("fault %q: want <request-index>:<status>", field)
		}
		i, err := strconv.Atoi(strings.TrimSpace(idx))
		if err != nil || i < 1 {
			return nil, fmt.Errorf("fault %q: request index must be a positive integer", field)
		}
		code, err := strconv.Atoi(strings.TrimSpace(status))
		if err != nil || code < 400 || code > 599 {
			return nil, fmt.Errorf("fault %q: status must be 4xx or 5xx", field)
		}
		out[i] = code
	}
	return out, nil
}

func newMeter(upstream string, faults map[int]int) (*meter, error) {
	u, err := url.Parse(strings.TrimSuffix(strings.TrimSpace(upstream), "/"))
	if err != nil || u.Scheme == "" || u.Host == "" {
		return nil, fmt.Errorf("meter upstream %q is not an absolute URL", upstream)
	}
	return &meter{upstream: u, client: &http.Client{}, faults: faults}, nil
}

// serve starts the proxy on an ephemeral loopback port and returns its base URL
// plus a stop function. Loopback only: the proxy carries provider credentials.
func (m *meter) serve() (base string, stop func(), err error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", nil, err
	}
	srv := &http.Server{Handler: m}
	go func() { _ = srv.Serve(ln) }()
	return "http://" + ln.Addr().String(), func() { _ = srv.Close() }, nil
}

func (m *meter) snapshot() meterUsage {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.meterUsage
}

func (m *meter) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	m.mu.Lock()
	m.Requests++
	index := m.Requests
	status, faulted := m.faults[index]
	if faulted {
		m.Injected++
	}
	m.mu.Unlock()

	if faulted {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		fmt.Fprintf(w, `{"error":{"message":"injected by e2ebench meter at request %d","type":"bench_fault"}}`, index)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "read body: "+err.Error(), http.StatusBadGateway)
		return
	}
	body = requestUsageOptIn(body)

	target := *m.upstream
	target.Path = strings.TrimSuffix(m.upstream.Path, "/") + r.URL.Path
	target.RawQuery = r.URL.RawQuery
	req, err := http.NewRequestWithContext(r.Context(), r.Method, target.String(), bytes.NewReader(body))
	if err != nil {
		http.Error(w, "build request: "+err.Error(), http.StatusBadGateway)
		return
	}
	for key, values := range r.Header {
		if strings.EqualFold(key, "Host") || strings.EqualFold(key, "Content-Length") {
			continue
		}
		req.Header[key] = values
	}
	resp, err := m.client.Do(req)
	if err != nil {
		http.Error(w, "upstream: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	maps.Copy(w.Header(), resp.Header)
	w.WriteHeader(resp.StatusCode)
	if strings.Contains(resp.Header.Get("Content-Type"), "event-stream") {
		m.pipeStream(w, resp.Body)
		return
	}
	m.pipeJSON(w, resp.Body)
}

// requestUsageOptIn asks for a usage block on streamed completions. Without it
// an OpenAI-compatible stream may carry none at all, and a harness that never
// asks would measure as free.
func requestUsageOptIn(body []byte) []byte {
	var payload map[string]any
	if json.Unmarshal(body, &payload) != nil {
		return body
	}
	if stream, _ := payload["stream"].(bool); !stream {
		return body
	}
	if _, ok := payload["stream_options"]; ok {
		return body
	}
	payload["stream_options"] = map[string]any{"include_usage": true}
	out, err := json.Marshal(payload)
	if err != nil {
		return body
	}
	return out
}

func (m *meter) pipeJSON(w http.ResponseWriter, body io.Reader) {
	data, err := io.ReadAll(body)
	if err != nil {
		return
	}
	_, _ = w.Write(data)
	if !m.recordUsage(data) {
		m.noteMissingUsage()
	}
}

// pipeStream forwards SSE frames as they arrive — a buffered stream would
// change the harness's observed latency, which other metrics depend on — and
// reads usage out of the frames on the way past.
func (m *meter) pipeStream(w http.ResponseWriter, body io.Reader) {
	flusher, _ := w.(http.Flusher)
	reader := bufio.NewReader(body)
	seen := false
	for {
		line, err := reader.ReadBytes('\n')
		if len(line) > 0 {
			_, _ = w.Write(line)
			if flusher != nil {
				flusher.Flush()
			}
			if payload, ok := bytes.CutPrefix(bytes.TrimSpace(line), []byte("data:")); ok {
				if m.recordUsage(bytes.TrimSpace(payload)) {
					seen = true
				}
			}
		}
		if err != nil {
			break
		}
	}
	if !seen {
		m.noteMissingUsage()
	}
}

func (m *meter) noteMissingUsage() {
	m.mu.Lock()
	m.WithoutUsage++
	m.mu.Unlock()
}

// recordUsage folds one payload's usage block in, reporting whether it had one.
// Both cache spellings are read: DeepSeek's explicit hit/miss split and the
// OpenAI-standard prompt_tokens_details.cached_tokens.
func (m *meter) recordUsage(payload []byte) bool {
	var doc struct {
		Usage *struct {
			PromptTokens         int `json:"prompt_tokens"`
			CompletionTokens     int `json:"completion_tokens"`
			PromptCacheHitTokens int `json:"prompt_cache_hit_tokens"`
			PromptCacheMissToken int `json:"prompt_cache_miss_tokens"`
			PromptTokensDetails  *struct {
				CachedTokens int `json:"cached_tokens"`
			} `json:"prompt_tokens_details"`
		} `json:"usage"`
	}
	if json.Unmarshal(payload, &doc) != nil || doc.Usage == nil {
		return false
	}
	hit, miss := doc.Usage.PromptCacheHitTokens, doc.Usage.PromptCacheMissToken
	if hit == 0 && miss == 0 && doc.Usage.PromptTokensDetails != nil {
		hit = doc.Usage.PromptTokensDetails.CachedTokens
		miss = doc.Usage.PromptTokens - hit
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.PromptTokens += doc.Usage.PromptTokens
	m.CompletionTokens += doc.Usage.CompletionTokens
	m.CacheHitTokens += hit
	m.CacheMissTokens += miss
	return true
}
