package selkies

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
	"testing"
)

func TestSessionsIDs(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"sessions":[{"id":"a"},{"id":7},{}]}`))
	}))
	defer srv.Close()
	_, port, _ := net.SplitHostPort(srv.Listener.Addr().String())
	n, _ := strconv.Atoi(port)
	got, err := Sessions(n)(context.Background())
	if err != nil || !reflect.DeepEqual(got, []string{"a", "7", ""}) {
		t.Fatalf("got %v, %v", got, err)
	}
}
