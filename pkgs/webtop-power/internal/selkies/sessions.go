// Package selkies reads the connected clients from the Selkies server.
package selkies

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// Sessions returns a func listing the ids of the connected Selkies sessions. A session
// without an id field is listed as "" (callers then only get the count).
func Sessions(port int) func(ctx context.Context) ([]string, error) {
	url := fmt.Sprintf("http://127.0.0.1:%d/api/sessions", port)
	hc := &http.Client{Timeout: 5 * time.Second}
	return func(ctx context.Context) ([]string, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return nil, err
		}
		resp, err := hc.Do(req)
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
		}
		var v struct {
			Sessions []struct {
				ID any `json:"id"`
			} `json:"sessions"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&v); err != nil {
			return nil, err
		}
		ids := make([]string, len(v.Sessions))
		for i, s := range v.Sessions {
			if s.ID != nil {
				ids[i] = fmt.Sprint(s.ID)
			}
		}
		return ids, nil
	}
}
