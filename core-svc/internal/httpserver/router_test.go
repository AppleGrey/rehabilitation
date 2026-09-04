package httpserver

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"

	"rehabilitation/core-svc/internal/auth"
	"rehabilitation/core-svc/internal/ota"
	"rehabilitation/core-svc/internal/program"
	"rehabilitation/core-svc/internal/video"
)

// 路由冲突在 gin 里是注册期 panic，而 main() 要先连上数据库才会走到注册。
// 这个测试不碰 DB/MinIO（handler 只在请求时才用到它们），纯粹保证路由表能装起来，
// 并且鉴权边界符合预期：哪些是公开的、哪些必须带令牌。
func newTestRouter(t *testing.T) *gin.Engine {
	t.Helper()
	gin.SetMode(gin.TestMode)

	secret := []byte("router-test-secret")
	authRepo := auth.NewRepo(nil)
	return NewRouter(
		video.NewHandler(video.NewService(video.NewRepo(nil), nil)),
		program.NewHandler(program.NewRepo(nil), nil),
		ota.NewHandler(ota.NewRepo(nil), nil),
		auth.NewHandler(authRepo, secret, time.Hour, time.Hour),
		auth.NewGuard(secret, "svc-token", authRepo),
	)
}

func TestRouterRegistersWithoutConflict(t *testing.T) {
	r := newTestRouter(t)

	want := map[string]string{
		"GET /api/health":                    "",
		"GET /api/videos":                    "",
		"GET /api/videos/:video_id/play":     "",
		"POST /api/auth/register":            "",
		"POST /api/auth/login":               "",
		"GET /api/auth/me":                   "",
		"POST /api/auth/password":            "",
		"POST /api/programs":                 "",
		"GET /api/programs":                  "",
		"DELETE /api/programs/:id":           "",
		"GET /api/uploads/:task_id/play":     "",
		"GET /api/admin/users":               "",
		"GET /api/admin/users/:id":           "",
		"POST /api/admin/users/:id/status":   "",
		"POST /api/admin/admins":             "",
		"DELETE /api/admin/admins/:id":       "",
		"GET /api/app/update/check":          "",
		"GET /api/app/releases/:id/download": "",
	}
	got := map[string]bool{}
	for _, ri := range r.Routes() {
		got[ri.Method+" "+ri.Path] = true
	}
	for path := range want {
		if !got[path] {
			t.Errorf("路由缺失: %s", path)
		}
	}
}

// 公开路由不该因为缺令牌就 401：视频与 OTA 在登录前就要能用。
//
// 这里只断言「没被鉴权挡住」。因为 repo 是 nil，请求打到业务 handler 后会 panic 并被
// gin.Recovery 兜成 500 —— 那反而正好证明请求穿过了中间件链，日志里的堆栈是预期的。
func TestPublicRoutesDoNotRequireAuth(t *testing.T) {
	r := newTestRouter(t)
	for _, path := range []string{"/api/health", "/api/app/update/check"} {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, path, nil))
		if w.Code == http.StatusUnauthorized {
			t.Errorf("%s 不应要求登录（got 401）", path)
		}
	}
}

// 受保护路由在没有任何凭证时必须 401，且不能落到业务 handler（那会空指针）。
func TestProtectedRoutesRequireCredential(t *testing.T) {
	r := newTestRouter(t)
	cases := []struct{ method, path string }{
		{http.MethodGet, "/api/programs"},
		{http.MethodGet, "/api/programs/abc"},
		{http.MethodDelete, "/api/programs/abc"},
		{http.MethodGet, "/api/uploads/abc/play"},
		{http.MethodGet, "/api/admin/users"},
		{http.MethodPost, "/api/admin/admins"},
		{http.MethodGet, "/api/auth/me"},
	}
	for _, c := range cases {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest(c.method, c.path, nil))
		if w.Code != http.StatusUnauthorized {
			t.Errorf("%s %s: want 401, got %d", c.method, c.path, w.Code)
		}
	}
}

// 错误的服务令牌不能放行（常数时间比较也要真的比对内容）。
func TestWrongServiceTokenRejected(t *testing.T) {
	r := newTestRouter(t)
	req := httptest.NewRequest(http.MethodGet, "/api/programs", nil)
	req.Header.Set(auth.ServiceTokenHeader, "not-the-token")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("want 401 for wrong service token, got %d", w.Code)
	}
}
